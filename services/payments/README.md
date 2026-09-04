# Сервис оплаты (payments)

Управление подпиской Pro «Препресс-Планер». **Заглушка**: заказ создаётся,
«оплата» подтверждается тестовым вызовом (или вебхуком-заглушкой), подписка
продлевается. Реальный платёжный провайдер подключается позже — контракт
(checkout → order → confirm/webhook) уже заложен.

Токены проверяются HMAC-подписью (общий `PP_AUTH_SECRET` с сервисом auth) —
без HTTP-зависимости между сервисами. Пользователь — claim «sub» токена.
Хранилище — SQLite (`PP_DATA_DIR/payments.db`).

## API

- `GET  /healthz` — статус, список тарифов
- `GET  /payments/plans` — тарифы (month 990 ₽/мес, year 9900 ₽/год)
- `POST /payments/checkout` (Bearer) `{plan}` → `{order_id, plan, amount_rub,
  status: pending, url, hint}`
- `POST /payments/orders/{id}/confirm` (Bearer) — тестовая оплата заказа
- `POST /payments/webhook` `{order_id}` — заглушка вебхука провайдера
- `GET  /payments/subscription` (Bearer) → `{plan, pro, until}`

## env

| Переменная | По умолчанию | Назначение |
|---|---|---|
| `PP_AUTH_SECRET` | — (обязателен) | Общий секрет с auth (≥ 16 символов) |
| `PP_DATA_DIR` | `<сервис>/data` | Каталог БД |
| `PP_PUBLIC_BASE` | пусто | Публичный адрес для `url` оплаты |

## Локальный запуск

```bash
pip install -r requirements.txt
set PP_AUTH_SECRET=...
uvicorn payments_app.main:app --port 8122
```

## Docker

```bash
docker build -t pp-payments .
docker run -p 8122:8122 -e PP_AUTH_SECRET=... -v pay-data:/srv/payments/data pp-payments
```

## Тесты

```bash
python -m pytest tests -q
```
