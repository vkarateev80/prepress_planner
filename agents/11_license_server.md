# Агент 11 — Микросервисы авторизации (services/auth) и оплаты (services/payments)

> **Актуализация 2026-09-07 (HEAD 448dcba):** статус — частично устарело.
> - Тело контракта (auth+payments) соответствует финальной архитектуре и реализовано: `services/auth` (:8121) и `services/payments` (:8122) входят в прод-стек (`deploy/docker-compose.yml`), клиент ходит на них через `AccountGatewayHttp` (`app/lib/license/account_client.dart`).
> - ВАЖНО: исторический «license server» (`services/license` — тема контракта по имени файла) в прод-стек НЕ входит и клиентом не вызывается: в `app/lib/main.dart` `LicenseClient()` создаётся **без serverUrl** → только локальный офлайн-триал (`app/lib/license/license_client.dart`).
> - Маршруты `/admin/keys` и `/webhooks/*` license-сервиса — без аутентификации, дефолтный секрет `dev-secret-change-me`; см. `SECURITY.md` («осиротевший license-сервис»). Исправления отложены.
> - Ограничения продакшена: forgot без SMTP возвращает код в ответе (К-1), оплата — заглушка (К-4), rate limiting отсутствует (К-5) — см. `SECURITY.md`.

## Роль (Ф4)
Аккаунты email+пароль и подписка Pro (месяц/год) как два микросервиса.
Платёжный провайдер — заглушка (checkout → confirm/webhook), контракт заложен
под подключение ЮKassa/Robokassa/Stripe позже.

## Ключевые решения
- **Серверные сессии** (не stateless-токены): таблица sessions, opaque-токен,
  в БД — только sha256. Выход реально отзывает сессию.
- **Лимит устройств 1/1**: login/register принимают `device_id` (machine_id
  приложения); новый вход вытесняет прежние сессии пользователя.
- **Payments не знает секрета**: проверяет токен внутренним вызовом auth
  `POST /auth/verify` (env `PP_AUTH_URL`); отзыв сессии виден сразу.
- **Сброс пароля**: `/auth/forgot` → одноразовый код (6 цифр, TTL) на email
  через SMTP; без SMTP (dev) код возвращается в ответе `dev_code`.
  `/auth/reset` меняет пароль и отзывает все сессии.

## API auth (порт 8121)
- `POST /auth/register` `{email, password, device_id}` → `{token, user}`
- `POST /auth/login` `{email, password, device_id}` → `{token, user}`
- `POST /auth/logout` (Bearer) — отзыв сессии
- `GET /auth/me` (Bearer)
- `GET /auth/devices` (Bearer) → `{devices: [{device_id, current}], limit: 1}`
- `POST /auth/verify` (Bearer) — внутренний вызов payments → `{sub, email}`
- `POST /auth/forgot` `{email}` → `{ok, dev_code?}`
- `POST /auth/reset` `{email, code, new_password}` → `{ok}`
- `GET /healthz` → sessions: server-side, device_limit, smtp

## API payments (порт 8122)
- `GET /payments/plans` — month 990 ₽ / year 9900 ₽
- `POST /payments/checkout` (Bearer) `{plan}` → заказ pending
- `POST /payments/orders/{id}/confirm` (Bearer) — тестовая оплата
- `POST /payments/webhook` `{order_id}` — заглушка вебхука
- `GET /payments/subscription` (Bearer) → `{plan, pro, until}`

## env
- auth: `PP_AUTH_SECRET` (≥16), `PP_DATA_DIR`, `PP_TOKEN_TTL` (ч),
  `PP_RESET_TTL` (мин), `PP_SMTP_HOST/PORT/USER/PASSWORD/FROM`, `PP_SMTP_SSL`
- payments: `PP_AUTH_URL` (обязателен; в docker `http://auth:8121`),
  `PP_DATA_DIR`, `PP_PUBLIC_BASE`

## Тесты (pytest)
- auth: register/login/me; повторный register 409; неверный пароль 401;
  **1/1: вход с dev-b отзывает dev-a** (старый токен → 401 me);
  logout отзывает; forgot+reset (dev-код, старый пароль не подходит,
  одноразовость кода); /auth/verify.
- payments: checkout без токена 401; полный цикл checkout→confirm→Pro;
  цепочка продлений; чужой заказ 404; вебхук; неверный план 422;
  **отозванный токен (verify → 401) отклоняется**.

## Критерии приёмки
1. `pytest services/auth/tests services/payments/tests` — зелёный.
2. E2E: вход со «второго устройства» вытесняет первое и в auth, и в payments.
3. .env.example без секретов; README каждого сервиса.
