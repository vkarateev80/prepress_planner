# Сервис авторизации (auth)

Аккаунты email+пароль для «Препресс-Планер»: регистрация, вход, выход,
проверка токена, сброс пароля, список устройств.

**Сессии — серверные**: таблица `sessions`, токены opaque
(`secrets.token_urlsafe(32)`); в БД хранится только sha256 токена. Выход
реально отзывает сессию; **лимит устройств 1/1** — новый вход с другого
`device_id` вытесняет прежние сессии пользователя (в т.ч. при регистрации).
Пароли — PBKDF2-HMAC-SHA256, 200 000 итераций, соль; сравнение constant-time.
Payments проверяет токены живым внутренним вызовом `POST /auth/verify`.
Хранилище — SQLite (`PP_DATA_DIR/auth.db`).

> Статус на 2026-09-07: сервис развёрнут в проде (`deploy/`, порт 8121).
> Известные ограничения безопасности (dev-код в ответе `forgot` при пустом
> SMTP — К-1, отсутствие rate-limit — К-5 и др.) — см. `SECURITY.md` в корне
> репозитория.

## API

- `POST /auth/register` `{email, password, device_id}` → `{token, user}`
- `POST /auth/login` `{email, password, device_id}` → `{token, user}`
  (лимит 1/1: прежние сессии пользователя отзываются)
- `POST /auth/logout` (Bearer) → `{ok}` (отзывается именно эта сессия)
- `GET /auth/me` (Bearer) → `{user: {sub, email, device_id}}`
- `GET /auth/devices` (Bearer) → `{devices: [{device_id, current, ...}], limit: 1}`
- `POST /auth/verify` (Bearer) — внутренний вызов payments → `{sub, email}`
- `POST /auth/forgot` `{email}` → `{ok}` (+ `dev_code`, если SMTP не настроен)
- `POST /auth/reset` `{email, code, new_password}` → `{ok}` (сессии отзываются)
- `GET /healthz` → `{status, service, db, sessions, device_limit, smtp,
  reset_ttl_min}`

## Сброс пароля

`/auth/forgot` создаёт одноразовый код **6 цифр**, TTL `PP_RESET_TTL`
(по умолчанию 30 минут), и отправляет его на email через SMTP (`PP_SMTP_HOST`,
STARTTLS 587, или сразу TLS 465 при `PP_SMTP_SSL=1`). Если SMTP не настроен
(в проде `PP_SMTP_HOST` пуст) — **dev-режим**: код возвращается в ответе
(`dev_code`), чтобы поток можно было проверить. Такой же фолбэк срабатывает,
если письмо не удалось отправить. При несуществующем email ответ всё равно
`ok` (с `dev_hint` в dev-режиме), чтобы не раскрывать наличие аккаунта.

## env

| Переменная | По умолчанию | Назначение |
|---|---|---|
| `PP_AUTH_SECRET` | — (обязателен) | Секрет (≥ 16 символов); **не используется для подписи** — требуется для запуска (совместимость) |
| `PP_DATA_DIR` | `<сервис>/data` | Каталог БД |
| `PP_TOKEN_TTL` | `720` | Срок сессии, часы (30 дней) |
| `PP_RESET_TTL` | `30` | Срок кода сброса, минуты |
| `PP_SMTP_HOST/PORT/USER/PASSWORD/FROM` | — | Почта для сброса (SMTP) |
| `PP_SMTP_SSL` | пусто | `1` = TLS сразу (порт 465) |

## Локальный запуск

```bash
pip install -r requirements.txt
set PP_AUTH_SECRET=...
uvicorn auth_app.main:app --port 8121
```

## Docker

Образ: `services/auth/Dockerfile` (порт 8121). В проде сервис поднимается из
`deploy/docker-compose.yml` (или `services/docker-compose.yml`) вместе с
остальным стеком:

```bash
cd deploy
docker compose up -d --build
curl http://127.0.0.1:8121/healthz
```

## Тесты

```bash
python -m pytest tests -q
```
