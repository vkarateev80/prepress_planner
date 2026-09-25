# Агент 11 — Микросервисы авторизации (services/auth) и оплаты (services/payments)

> Статус: раздел **auth обновлён под SaaS** (System Design v1, ADR-4, §12.2,
> §13.1; PRD v2, F-19). Лимит устройств 1/1 и `dev_code` удалены. Раздел
> payments описывает текущую заглушку — заменяется billing-сервисом на ЮKassa
> (System Design v1, ADR-3).

## Роль (Ф4)
Аккаунты email+пароль и подписка Pro (месяц/год) как два микросервиса.

## Ключевые решения (auth)
- **Серверные сессии** (не stateless-токены): таблица sessions, opaque-токен,
  в БД — только sha256. Выход реально отзывает сессию
  (`/auth/logout`, `/auth/sessions/{id}/revoke`).
- **Мультитенантность вместо лимита 1/1**: `organizations` + `memberships`
  с ролями `owner/admin/member/viewer`. У пользователя может быть несколько
  активных сессий; `device_id` необязателен и ничего не вытесняет.
- **Payments/billing не знает секрета**: проверяет токен внутренним вызовом
  auth `POST /auth/verify` (env `PP_AUTH_URL`) → `{sub, email, orgs[]}`;
  отзыв сессии виден сразу.
- **Legacy `services/license`** (machine-id, офлайн-токены) в SaaS-пути не
  используется: auth его не вызывает.
- **Пароли**: pbkdf2_hmac sha256 200k, соль `secrets.token_hex(16)`,
  формат `salt$digest` — без изменений (N-5).
- **Сброс пароля**: `/auth/forgot` → одноразовый код (6 цифр, TTL 30 мин,
  в БД только sha256) уходит **только** по SMTP; в ответе код не
  возвращается ни в каком режиме. `/auth/reset` меняет пароль и отзывает
  все сессии пользователя.

## API auth (порт 8121)
- `POST /auth/register` `{email, password, org_name?, device_id?}` → `201 {token, user, orgs}`
- `POST /auth/login` `{email, password, device_id?}` → `{token, user, orgs}`
- `POST /auth/logout` (Bearer) — отзыв текущей сессии
- `GET /auth/me` (Bearer) → `{user, orgs, memberships}`
- `GET /auth/sessions` (Bearer) → `{sessions:[{id,current,…}], count}`
- `POST /auth/sessions/{id}/revoke` (Bearer)
- `GET /auth/devices` (Bearer) — совместимость с desktop, без лимита
- `GET /auth/orgs`, `POST /auth/orgs` (Bearer) — организации и роли
- `POST /auth/verify` (Bearer) — внутренний вызов billing/api → `{sub, email, orgs}`
- `POST /auth/forgot` `{email}` → `{ok}` (код только по SMTP)
- `POST /auth/reset` `{email, code, new_password}` → `{ok}`
- `GET /healthz` → sessions: server-side, device_policy: multi, smtp

## API payments (порт 8122, заглушка → billing)
- `GET /payments/plans` — month 990 ₽ / year 9900 ₽
- `POST /payments/checkout` (Bearer) `{plan}` → заказ pending
- `POST /payments/orders/{id}/confirm` (Bearer) — тестовая оплата
- `POST /payments/webhook` `{order_id}` — заглушка вебхука
- `GET /payments/subscription` (Bearer) → `{plan, pro, until}`

## env
- auth: `PP_AUTH_SECRET` (≥16), `PP_DATA_DIR`, `PP_TOKEN_TTL` (ч),
  `PP_RESET_TTL` (мин), `PP_DEFAULT_ORG` (1/0), `PP_SMTP_HOST/PORT/USER/
  PASSWORD/FROM`, `PP_SMTP_SSL`
- payments: `PP_AUTH_URL` (обязателен; в docker `http://auth:8121`),
  `PP_DATA_DIR`, `PP_PUBLIC_BASE`

## Тесты (pytest)
- auth: healthz (device_policy=multi); register с/без `org_name` (owner,
  memberships, `PP_DEFAULT_ORG=0` → без организации); повторный register 409;
  неверный пароль 401; **мультисессии: вход с dev-b НЕ отзывает dev-a**;
  отзыв сессии по id; logout отзывает только текущую; forgot+reset
  (кода в ответе нет, одноразовость, все сессии отозваны); `/auth/verify`
  с `orgs`; формат pbkdf2-хеша; sha256 в sessions; миграция legacy-БД.
- payments: checkout без токена 401; полный цикл checkout→confirm→Pro;
  цепочка продлений; чужой заказ 404; вебхук; неверный план 422;
  **отозванный токен (verify → 401) отклоняется**.

## Критерии приёмки
1. `pytest services/auth/tests services/payments/tests` — зелёный.
2. E2E: пользователь работает с двух устройств одновременно (обе сессии
   живы), сессия отзывается точечно; организация/роль приходит в verify.
3. .env.example без секретов; README каждого сервиса.
