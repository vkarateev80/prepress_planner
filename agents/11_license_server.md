# Агент 11 — Микросервисы авторизации (services/auth) и оплаты (services/payments)

## Роль (Ф4)
Аккаунты email+пароль и подписка Pro (месяц/год) как два микросервиса
(вместо единого license-сервера на machine-id). Платёжный провайдер — пока
заглушка (checkout → confirm/webhook), контракт заложен под подключение
ЮKassa/Robokassa/Stripe позже.

## Создаваемые файлы
```
services/auth/auth_app/main.py       # FastAPI: /auth/register|login|logout|me, /healthz
services/auth/auth_app/__init__.py
services/auth/tests/test_auth.py
services/auth/requirements.txt        # fastapi, uvicorn, pydantic, pytest, httpx
services/auth/Dockerfile              # python:3.12-slim, порт 8121
services/auth/README.md

services/payments/payments_app/main.py  # /payments/plans|checkout|orders/{id}/confirm|webhook|subscription
services/payments/payments_app/__init__.py
services/payments/tests/test_payments.py
services/payments/requirements.txt
services/payments/Dockerfile           # порт 8122
services/payments/README.md

services/docker-compose.yml            # converter+auth+payments (общий секрет)
services/.env.example                  # PP_AUTH_SECRET
```

## API
- auth: `POST /auth/register` `{email, password}` → `{token, user}`;
  `POST /auth/login` → то же; `POST /auth/logout` (Bearer);
  `GET /auth/me` (Bearer); `GET /healthz`.
- payments: `GET /payments/plans`; `POST /payments/checkout` `{plan}` →
  `{order_id, plan, amount_rub, status: pending, url, hint}`;
  `POST /payments/orders/{id}/confirm` (Bearer) — тестовая оплата;
  `POST /payments/webhook` `{order_id}` — заглушка вебхука провайдера;
  `GET /payments/subscription` → `{plan, pro, until}`; `GET /healthz`.

## Ключевые решения
- Токены — HMAC-SHA256, stateless; подпись проверяют и auth, и payments
  (общий `PP_AUTH_SECRET`). Сервисы не ходят друг к другу по HTTP.
- Пароли — pbkdf2_hmac (sha256, 200k итераций, соль на пользователя).
- Хранилище — SQLite: auth → users; payments → orders + subscriptions.
- Подписка продлевается от конца текущей (если активна), иначе от сейчас.
- Заказы приватны: confirm видит только заказ своего user_id (sub токена).
- env: `PP_AUTH_SECRET` (обязателен, ≥16), `PP_DATA_DIR`, `PP_TOKEN_TTL`,
  `PP_PUBLIC_BASE` (payments), `PP_MAX_MB` не нужен.
- Ошибки — русские тексты в `detail`; 401/404/409/422 по смыслу.

## Тесты (pytest)
1. auth: register→login→me; повторный register → 409; неверный пароль → 401;
   некорректный email/короткий пароль → 422; me без токена → 401;
   round-trip verify_token.
2. payments: checkout требует токен; полный цикл checkout→confirm→Pro;
   цепочка продлений (год после месяца от конца); чужой заказ → 404;
   вебхук-заглушка; неизвестный план → 422.

## Критерии приёмки
1. `pytest services/auth/tests services/payments/tests` — зелёный.
2. Образы собираются (`docker build`), /healthz отвечает.
3. .env.example без секретов; README с API каждого сервиса.
