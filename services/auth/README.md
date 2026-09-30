# Сервис авторизации (auth)

Self-hosted auth «Препресс-Планер» (SaaS): аккаунты email+пароль,
**мультитенантность** (организации → участники → роли), серверные сессии,
восстановление пароля через SMTP. Основное: System Design v1, ADR-4, §12.2,
§13.1; PRD v2, F-19.

- **Сессии — серверные**: таблица `sessions`, токены opaque (в БД — только
  sha256), отзыв работает индивидуально (`/auth/logout`,
  `/auth/sessions/{id}/revoke`). Политика **1/1 (вытеснение)**: у аккаунта
  ровно одна активная сессия — вход (`login`/`confirm`) отзывает все
  прежние; `device_id` необязателен.
- **Пароли** — `pbkdf2_hmac sha256`, 200 000 итераций, соль
  `secrets.token_hex(16)`, формат `salt$digest_hex` (инвариант N-5, без
  изменений).
- **Роли**: `owner`, `admin`, `member`, `viewer` (таблица `memberships`).
- **Legacy `services/license`** (machine-id, офлайн-токены) в SaaS-пути не
  используется: auth его не вызывает и не зависит от него. Модель «одно
  устройство» заменена моделью «организация → участники → роли».
- Хранилище — SQLite (`PP_DATA_DIR/auth.db`); зависимости — стандартная
  библиотека Python + fastapi/pydantic/uvicorn (SMTP — `smtplib`/`email`).

## API

| Метод/путь | Запрос | Ответ |
|---|---|---|
| `POST /auth/register` | `{name, email, password, org_name?, device_id?}` | `202 {pending:true, email, dev_email_code?}` — сессии НЕТ |
| `POST /auth/confirm` | `{email, email_code, device_id?}` | `201 {token, user{id,email}, orgs[{org_id,role}]}` / `400` неверный код / `404` нет регистрации / `409` уже подтверждён |
| `POST /auth/confirm/resend` | `{email}` | `200 {ok:true, dev_email_code?}` / `429` кулдаун |
| `POST /auth/login` | `{email, password, device_id?}` | `200 {token, user, orgs[]}` (вытесняет прежние сессии — 1/1) / `403` аккаунт не подтверждён |
| `POST /auth/logout` | Bearer | `200 {ok, user_id}` — отзывается только эта сессия |
| `GET /auth/me` | Bearer | `200 {user, orgs[], memberships[], session}` |
| `GET /auth/sessions` | Bearer | `200 {sessions:[{id,device_id,current,created_at,expires_at}], count}` |
| `POST /auth/sessions/{id}/revoke` | Bearer | `200 {ok, revoked}` / `404` |
| `GET /auth/devices` | Bearer | совместимость с desktop: `{devices, current, count, device_policy:"single"}` (1/1 — обычно одна запись) |
| `GET /auth/orgs` | Bearer | `200 {orgs:[{org_id,name,role,created_at}]}` |
| `POST /auth/orgs` | Bearer `{name}` | `201 {org_id, name, role:"owner"}` |
| `GET /auth/orgs/{org_id}/members` | Bearer (член org) | `200 {members:[{user_id,email,role,invited_by,created_at}]}` |
| `POST /auth/orgs/{org_id}/members` | Bearer **owner/admin** `{email, role?}` (`member`/`viewer`) | `201 {status:"added"\|"invited", …}` — роли `member`/`viewer`/`admin` (admin назначает админ-панель); существующий пользователь добавляется сразу; неизвестный email → invite (TTL 7 дней, sha256 в БД; письмо при настроенном SMTP, иначе `code` в ответе — dev-режим) / `409` дубль |
| `POST /auth/orgs/{org_id}/invites/accept` | Bearer `{code}` | `200 {ok, org_id, role}`; `403` email не совпал, `404` код, `409` истёк/принят/уже участник. Автоприём — при регистрации по email invite'а |
| `DELETE /auth/orgs/{org_id}/members/{user_id}` | Bearer **owner/admin** | `200 {ok:true}`; `409` последний owner |
| `POST /auth/verify` | Bearer (внутренний вызов billing/api) | `200 {sub, email, orgs:[{org_id,role}]}` |
| `POST /auth/forgot` | `{email}` | `200 {ok:true}` — всегда, кода в ответе нет |
| `POST /auth/reset` | `{email, code, new_password}` | `200 {ok:true}` / `400` код / `404` email |
| `GET /healthz` | — | статус, `device_policy:"single"` (лимит 1), `multitenant:true`, `smtp`, `verify:"email"`, TTL |

**Регистрация двухфазная** (подтверждение почты): `register`
создаёт пользователя **без сессии** и шлёт 6-значный код (TTL =
`PP_RESET_TTL`, в БД только sha256) на email через SMTP; без SMTP код
возвращается в `dev_email_code`. `confirm` сверяет код и выдаёт сессию.
`confirm/resend` переотправляет код (кулдаун `PP_RESEND_COOLDOWN`,
дефолт 60 с). Вход (`login`) до подтверждения — `403`.
SMS-подтверждение удалено (HANDOFF §24): колонки `users.phone` /
`phone_verified_at` сохранены для исторических данных.

`org_name` передан → создаётся организация (при `register`), пользователь —
`owner`. Без `org_name` → личная организация (email как имя) при
`PP_DEFAULT_ORG=1` (по умолчанию) либо пользователь **без** организации при
`PP_DEFAULT_ORG=0`. Оба пути поддержаны.

Ошибки: `409` email занят / уже подтверждён, `422` невалидный
email/короткий пароль, `401` неверные данные или мёртвый токен,
`403` нет доступа к организации или аккаунт не подтверждён.

## Подтверждение регистрации (почта)

`register` → 202 `pending`: создаётся пользователь (`email_verified_at`
= NULL), применяются приглашения и создаётся организация — но **сессии
нет**. Код (6 цифр, TTL `PP_RESET_TTL`) хранится в `verify_codes`
(sha256, свежий вытесняет предыдущий по `channel+dest`).

Доставка — email через SMTP (как при сбросе). Если SMTP не настроен,
`dev_email_code` возвращается в ответе (паттерн invites).

`confirm` сверяет код без погашения, затем погашает его, ставит
verified-метку и выдаёт сессию. `confirm/resend` — переотправка с
кулдауном `PP_RESEND_COOLDOWN` (429). Существующие на момент миграции
аккаунты помечаются подтверждёнными автоматически (одноразовый backfill).

## Сброс пароля

`/auth/forgot` создаёт одноразовый код (6 цифр, TTL `PP_RESET_TTL`, по
умолчанию 30 мин; в БД — только sha256) и отправляет его на email через SMTP
(`PP_SMTP_HOST`, STARTTLS 587 или SSL 465 при `PP_SMTP_SSL=1`). Код **не
возвращается в ответе ни в каком режиме** (в т.ч. без SMTP) и факт
существования email не раскрывается — ответ всегда `{ok:true}`; при
недоступном SMTP код не теряется из БД, но и не отдаётся клиенту.

`/auth/reset` проверяет sha256 кода, одноразовость и TTL, меняет пароль
(новый pbkdf2 200k), удаляет использованный код и **отзывает все сессии**
пользователя.

## Модель данных (SQLite)

```
users(id, email UNIQUE, password_hash, name, created_at, updated_at,
      phone, email_verified_at, phone_verified_at)
organizations(id, name, created_by, created_at, updated_at)
memberships(id, org_id, user_id, role, invited_by, created_at,
            UNIQUE(org_id,user_id))
sessions(token_hash PK sha256, user_id, device_id NULL, created_at,
         expires_at, revoked_at, meta)
reset_codes(email, user_id, code_hash sha256, created_at, expires_at, used)
verify_codes(id PK, channel 'email' (в SaaS-пути), dest, user_id,
             code_hash sha256, created_at, expires_at)
```

### Миграция с legacy-БД (v0.2)

`_init_db()` выполняется при старте и **сохраняет данные**: добавляет
`users.updated_at`, `sessions.revoked_at/meta`, `reset_codes.user_id`
(с обратным заполнением по email), создаёт `organizations`/`memberships` и
снимает legacy `NOT NULL` с `sessions.device_id` (пересоздание таблицы с
копированием строк). При добавлении колонок подтверждения (`phone`,
`email_verified_at`, `phone_verified_at` — одноразово) существующие
пользователи помечаются подтверждёнными (иначе потеряли бы вход);
новые после миграции регистрируются неподтверждёнными. Существующие
пользователи, сессии и коды сброса продолжают работать; до появления
своей организации пользователь просто не имеет memberships (организацию
можно создать через `POST /auth/orgs`).
Резервная копия перед обновлением прода — обязательна (см. runbook).

## env

| Переменная | По умолчанию | Назначение |
|---|---|---|
| `PP_AUTH_SECRET` | — (обязателен) | Секрет (≥ 16 символов) |
| `PP_DATA_DIR` | `<сервис>/data` | Каталог БД (`auth.db`) |
| `PP_TOKEN_TTL` | `720` | Срок сессии, часы (30 дней) |
| `PP_RESET_TTL` | `30` | Срок кода сброса, минуты |
| `PP_DEFAULT_ORG` | `1` | `1` — регистрация без `org_name` создаёт личную организацию; `0` — пользователь без организации |
| `PP_SMTP_HOST/PORT/USER/PASSWORD/FROM` | — | Почта для сброса и подтверждения (SMTP) |
| `PP_SMTP_SSL` | пусто | `1` = TLS сразу (порт 465) |
| `PP_RESEND_COOLDOWN` | `60` | Кулдаун переотправки кода подтверждения, секунд |

## Локальный запуск

```bash
pip install -r requirements.txt
export PP_AUTH_SECRET=...        # ≥ 16 символов
uvicorn auth_app.main:app --port 8121
curl -s http://127.0.0.1:8121/healthz
```

## Docker

```bash
docker build -t pp-auth .
docker run -p 8121:8121 -e PP_AUTH_SECRET=... -v auth-data:/srv/auth/data pp-auth
```

## Тесты

```bash
python -m pytest tests -q
```

Покрыто: healthz, двухфазная регистрация (register → confirm: 403 до
подтверждения, неверный код, повторный confirm 409, кулдаун resend 429),
регистрация с/без организации, роли и memberships,
политика 1/1 (вход вытесняет прежние сессии; неудачный вход сессию не трогает), отзыв сессии по id, logout,
forgot/reset (без `dev_code`, одноразовость, отзыв всех сессий),
`/auth/verify` с `orgs`, формат парольного хеша (pbkdf2 200k), sha256
токенов в БД, миграция legacy-БД (в т.ч. backfill подтверждений),
приглашения участников (F-19: список,
добавление/invite, accept, автоприём при регистрации, удаление, защита
последнего owner).

## Что дальше (вне этого сервиса)

- `PATCH /auth/orgs/{org_id}` (переименование организации).
- Очередь писем с ретраями и метрики доставки SMTP (runbook).
