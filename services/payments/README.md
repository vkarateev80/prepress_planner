# Сервис оплаты (payments)

Управление подпиской Pro «Препресс-Планер». **Заглушка до подключения
реального платёжного провайдера**: реальные деньги не списываются. Контракт
(checkout → order → confirm/webhook → subscription) уже заложен — подстановка
провайдера не меняет API.

Тарифы (`PLANS`): `month` — 990 ₽ / 30 дней, `year` — 9900 ₽ / 365 дней.

Поток:
1. `POST /payments/checkout` (Bearer) — создаёт заказ `pending` и возвращает
   тестовую ссылку оплаты (`url`, строится из `PP_PUBLIC_BASE`);
2. клиент «оплачивает» тестовым подтверждением —
   `POST /payments/orders/{id}/confirm` (Bearer): заказ помечается `paid`,
   подписка продлевается **от конца текущей активной подписки** (если она
   ещё действует), иначе — от текущего момента;
3. `POST /payments/webhook` — заглушка вебхука провайдера (по `order_id`);
4. `GET /payments/subscription` (Bearer) → текущая подписка.

Токены **не проверяются локально**: каждый защищённый запрос делает живой
вызов `POST {PP_AUTH_URL}/auth/verify` с Bearer. Это позволяет auth отзывать
сессии (выход, лимит устройств 1/1) — payments видит отзыв сразу; при
недоступности auth отвечает 503. Хранилище — SQLite (`PP_DATA_DIR/payments.db`).

> Статус на 2026-09-07: сервис развёрнут в проде (`deploy/`, порт 8122).
> Известные ограничения (Pro бесплатно через тестовое подтверждение и вебхук
> без подписи/аутентификации — К-4, отсутствие rate-limit — К-5) — см.
> `SECURITY.md` в корне репозитория.

## API

- `GET  /healthz` — статус, путь БД, список тарифов
- `GET  /payments/plans` — тарифы (`month` 990 ₽/30 дн, `year` 9900 ₽/365 дн) — без токена
- `POST /payments/checkout` (Bearer) `{plan}` → `{order_id, plan, title,
  amount_rub, status: pending, url, hint}`
- `POST /payments/orders/{order_id}/confirm` (Bearer) — тестовая оплата заказа
  (заказ `paid`, подписка продлевается от конца текущей)
- `POST /payments/webhook` `{order_id}` — заглушка вебхука (без подписи и
  аутентификации; `paid`, если заказ ещё `pending`)
- `GET  /payments/subscription` (Bearer) → `{plan, pro, until}`

## env

| Переменная | По умолчанию | Назначение |
|---|---|---|
| `PP_AUTH_URL` | — (обязателен) | Адрес auth (`http://auth:8121` в docker) |
| `PP_DATA_DIR` | `<сервис>/data` | Каталог БД |
| `PP_PUBLIC_BASE` | пусто | Публичный адрес сервиса для `url` оплаты (пусто → `url: null`) |

## Локальный запуск

```bash
pip install -r requirements.txt
set PP_AUTH_URL=http://127.0.0.1:8121
uvicorn payments_app.main:app --port 8122
```

## Docker

Образ: `services/payments/Dockerfile` (порт 8122). В проде сервис поднимается
из `deploy/docker-compose.yml` (или `services/docker-compose.yml`):

```bash
cd deploy
docker compose up -d --build
curl http://127.0.0.1:8122/healthz
```

## Тесты

```bash
python -m pytest tests -q
```
