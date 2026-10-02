# Сервис оплаты / billing (ЮKassa)

Подписка Pro «Препресс-Планер» для организаций (мультитенантность).
**Заглушка удалена**: реальный платёжный провайдер ЮKassa, вебхук со сверкой
объекта у провайдера, идемпотентные транзакции, продление подписки, возвраты и
entitlement-синхронизация прав.

Основание: **PRD v2** (F-20, F-21, F-22) и **System Design v1**
(**ADR-3** «Платёжный провайдер: ЮKassa + схема webhook/entitlement»,
§4 «Безопасность», §12.3 «Подписка/платежи», §13.2 «Data Model»).

## Что изменилось относительно заглушки

| Было (заглушка) | Стало (ADR-3) |
|---|---|
| `POST /payments/orders/{id}/confirm` — «тестовая оплата» | **удалено**; права даёт только вебхук ЮKassa (или ручное продление в БД) |
| `POST /payments/webhook {order_id}` без подписи | `POST /payments/webhook` — тело ЮKassa **не источник истины**: событие принимается только после сверки объекта у ЮKassa API (`GET /payments|/refunds/{id}` + статус). ЮKassa не шлёт HMAC; если подпись прислана шлюзом — сверяется дополнительно (fail closed при пустом секрете) |
| Подписка по `user_id`, без организаций | подписка по **`org_id`** (организация из `POST /auth/verify`) |
| Одна таблица `orders` + `subscriptions(user_id)` | `orders`, `transactions`, `subscriptions`, `entitlements`, `plans` (System Design §13.2) |
| Нет возвратов | `POST /payments/subscription/refund` (`POST /payments/refunds`) → `POST /refunds` ЮKassa |
| Клиент получал `hint`/`url` на «тестовую оплату» | клиент получает только `confirmation_url`; платёжные секреты — только в env |

Старые таблицы заглушки при первом старте **переименовываются** (не удаляются):
`orders` → `orders_stub_v0`, `subscriptions` → `subscriptions_stub_v0`.

## Структура

| Файл | Назначение |
|---|---|
| `payments_app/config.py` | env-настройки, тарифы, фичи гейтинга, нормализация планов/статусов |
| `payments_app/db.py` | слой БД: SQLite (`PP_DATA_DIR`) или PostgreSQL (`DB_URL`), DDL, миграция заглушки |
| `payments_app/store.py` | бизнес-логика: триал, заказы, идемпотентные транзакции, продление, возвраты, entitlements |
| `payments_app/provider.py` | интерфейс `PaymentProvider`, `YooKassaProvider` (urllib, без SDK), `UnconfiguredProvider`, сверка вебхука у провайдера + разбор |
| `payments_app/main.py` | FastAPI-эндпоинты, авторизация через auth, структурированные логи |

## API

Все пути — за единым origin (nginx, ADR-6); внутри сети сервис слушает 8122.
Аутентификация — `Authorization: Bearer <токен>`; организация берётся из выдачи
`POST {PP_AUTH_URL}/auth/verify` (`{sub, email, orgs:[{org_id, role}]}`), а
параметром `org_id` (query/тело) можно выбрать организацию пользователя.

| Метод/путь | Запрос | Ответ | Ошибки |
|---|---|---|---|
| `GET /healthz` | — | статус, БД, провайдер, тарифы, триал | 503 (БД недоступна) |
| `GET /payments/plans` | — | `[{plan,title,amount_rub,days,currency,features}]` | — |
| `GET /payments/free-plan` | — | тариф Free и его лимиты | — |
| `POST /payments/checkout` | Bearer `{plan, org_id?}` | `{order_id, confirmation_url, amount_rub, plan, status:"pending", …}` | 401/403/409/422/502/503 |
| `GET /payments/orders/{id}` | Bearer `?org_id=` | `{order_id, plan, amount_rub, currency, status, confirmation_url, …}` | 401/403/404 |
| `POST /payments/webhook` | тело ЮKassa (сверка у провайдера) | `{ok:true}` / `{ok:true, already:true}` | 401 (неверная присланная подпись), 404 (заказ), 413, 422 (событие/статус не подтверждён), 502 (провайдер/404), 503 (не настроена) |
| `GET /payments/subscription` | Bearer `?org_id=` | `{plan, plan_alias, status, pro, trial_active, trial_ends_at, until, current_period_end, cancel_at_period_end, features}` | 401/403/409 |
| `GET /payments/entitlement` | Bearer `?org_id=` | `{plan, status, pro, trial_active, features, until}` | 401/403/409 |
| `GET /entitlement` | Bearer `?org_id=` | то же (алиас для внутренних вызовов) | 401/403/409 |
| `GET /payments/transactions` | Bearer `?org_id=&limit=` | журнал событий провайдера (сверка) | 401/403/409 |
| `POST /payments/subscription/cancel` | Bearer `{org_id?}` | `{ok, cancel_at_period_end:true, until, status}` | 401/403/409 |
| `POST /payments/subscription/resume` | Bearer `{org_id?}` | `{ok, cancel_at_period_end:false, until, status}` | 401/403/409 |
| `POST /payments/subscription/refund` | Bearer **owner/admin** `{org_id?, order_id?, payment_id?, amount_rub?}` | `{ok, refund_id, status, amount_rub, order_id, payment_id, applied}` | 401/403/404/409/502/503 |
| `POST /payments/refunds` | то же (алиас) | то же | то же |

`POST /payments/orders/{id}/confirm` **не существует** (404) — заглушка удалена.
`confirmation_url` не является источником прав: клиент читает права из
`GET /payments/subscription` / `GET /payments/entitlement`.

## Схема webhook → entitlement (ADR-3)

1. `POST /payments/checkout` → заказ `pending` (`provider_order_id` = id платежа
   ЮKassa) → клиенту `confirmation_url`.
2. Пользователь платит на стороне ЮKassa → уведомление `POST /payments/webhook`:
   * **сверка у провайдера**: `GET /payments|/refunds/{id}` нашими ключами —
     статус объекта должен подтверждать событие (тело уведомления не
     источник истины; ЮKassa HMAC не шлёт — офиц. документация рекомендует
     именно проверку статуса/IP); если подпись прислана (шлюз) —
     дополнительно **HMAC-SHA256** по сырому телу (`YUKASSA_WEBHOOK_SECRET`);
     заголовки
     `X-Signature` / `Content-Signature` / `X-Webhook-Signature` /
     `X-Yookassa-Signature`, допустим префикс `sha256=`; пустой секрет → 503;
   * поиск заказа по `provider_order_id` (fallback — `metadata.order_id`, если
     ответ ЮKassa не успел сохраниться);
   * идемпотентная запись `transactions` (**UNIQUE `provider_payment_id`**);
   * продление `subscriptions` **от конца текущего периода** (+30/+365 дней);
   * пересчёт `entitlements` (Free/Pro).
3. Обрабатываемые события: `payment.succeeded`, `payment.canceled`,
   `refund.succeeded`. Прочие (`payment.waiting_for_capture` и т.п.) →
   `{ok:true, ignored:"<event>"}`; неизвестный заказ → 404 (видно в логах).

Повторное уведомление с тем же `provider_payment_id` период не удваивает:
ответ `{ok:true, already:true}`. Обработанные события всегда отвечают 2xx —
иначе ЮKassa будет ретраить.

## Триал и права (вне провайдера)

* Триал **15 дней** (`PP_TRIAL_DAYS`) ведёт этот сервис: при первом обращении
  организации создаётся подписка `trialing` с `trial_ends_at = сейчас + 15 дней`;
  платёж у провайдера до окончания триала не создаётся.
* `trial_active=true` — права Pro (фичи Pro) до `trial_ends_at`.
* Триал закончился, оплаты нет → статус `expired`, права **Free**.
* Оплата прошла (`payment.succeeded`) → `status=active`, права **Pro** на период
  тарифа; продление — от конца оплаченного периода.
* `past_due` (просроченное автопродление) и `canceled` (возврат) → права **Free**.
* `cancel_at_period_end=true` (отмена автопродления) права **не снимает** — они
  действуют до конца оплаченного периода.

| Тариф | Права (`features`) |
|---|---|
| Free | `{projects: 1, teo: false, reports: false}` |
| Pro (в т.ч. триал) | `{projects: null, teo: true, reports: true}` |

## Схема БД (System Design §13.2)

Типы переносимы между SQLite и PostgreSQL: `TEXT` (id/статусы/время ISO-8601 UTC),
`INTEGER` (деньги в рублях), `BOOLEAN`. `org_id`/`user_id` принадлежат auth — billing
хранит их как непрозрачные ссылки и фильтрует выборки по `org_id` (N-4).

| Таблица | Колонки |
|---|---|
| `plans` | `plan PK, title, amount_rub, days, currency, features, updated_at` |
| `orders` | `id PK, org_id, user_id, plan, amount_rub, currency, status (pending/paid/canceled/failed/refunded), provider_order_id, confirmation_url, created_at, paid_at, refunded_at` |
| `transactions` | `id PK, order_id, provider_payment_id UNIQUE, event_type, amount_rub, currency, status, raw_payload, received_at` + вычисляемые алиасы `amount` (=`amount_rub`), `created_at` (=`received_at`) |
| `subscriptions` | `id PK, org_id UNIQUE, plan (free/month/year), status (trialing/active/past_due/canceled/expired), trial_started_at, trial_ends_at, current_period_start, current_period_end, cancel_at_period_end, provider_subscription_id, created_at, updated_at` + вычисляемый алиас `current_period_ends_at` (=`current_period_end`) |
| `entitlements` | `id PK, org_id UNIQUE, plan (free/pro), status (free/pro), pro, features, "until", updated_at` |

Индексы: `orders(org_id)`, `orders(provider_order_id)`, `orders(status)`,
`transactions(order_id)`, `transactions(provider_payment_id)` (UNIQUE),
`subscriptions(org_id)` (UNIQUE), `subscriptions(status)`,
`entitlements(org_id)` (UNIQUE).

Столбцы-алиасы (`amount`, `created_at`, `current_period_ends_at`) — **вычисляемые**
(`GENERATED ALWAYS AS … STORED`, PostgreSQL 12+ / SQLite 3.31+): имена из task-spec
присутствуют без дублирования данных.

## env

| Переменная | По умолчанию | Назначение |
|---|---|---|
| `PP_AUTH_URL` | — (**обязателен**) | адрес auth (`http://auth:8121` в docker) |
| `DB_URL` | пусто → SQLite | `postgresql://pp_user:…@postgresql:5432/prepress_saas` |
| `PP_DATA_DIR` | `<сервис>/data` | каталог SQLite (`payments.db`) |
| `YUKASSA_SHOP_ID` | пусто | shopId ЮKassa (Basic-аутентификация) |
| `YUKASSA_SECRET_KEY` | пусто | секретный ключ ЮKassa (только env/секрет-менеджер) |
| `YUKASSA_WEBHOOK_SECRET` | пусто | секрет HMAC для ОПЦИОНАЛЬНОЙ подписи (сверяется, только если подпись прислана; основная защита — сверка объекта у API); прислана подпись + пусто → 503 |
| `YUKASSA_API_URL` | `https://api.yookassa.ru/v3` | API ЮKassa (замена для песочницы/тестов) |
| `YUKASSA_SAVE_PAYMENT_METHOD` | `0` | `1` — просить сохранить способ оплаты (автоплатежи; нужна активация у мерчанта) |
| `YUKASSA_RECEIPT_ENABLED` | `1` | `0` — не добавлять объект `receipt` (чек) в создание платежа |
| `YUKASSA_RECEIPT_VAT_CODE` | `1` | код НДС в чеке (`1` — НДС включён в цену; строка) |
| `PP_TRIAL_DAYS` | `15` | срок триала (вне провайдера) |
| `PP_PRO_MONTH_PRICE_RUB` | `5000` | цена Pro-месяца (30 дней) |
| `PP_PRO_YEAR_PRICE_RUB` | `50000` | цена Pro-года (365 дней) |
| `PP_PUBLIC_BASE` | пусто | публичный origin (ADR-6) для `return_url` |
| `PP_RETURN_PATH` | `/billing/return` | путь возврата после оплаты |
| `PP_RETURN_URL` | пусто | явный `return_url` (переопределяет `PP_PUBLIC_BASE`) |
| `PP_WEBHOOK_MAX_BYTES` | `65536` | лимит тела вебхука |
| `PP_RENEWAL_ENABLED` | `1` | `0` — выключить фоновое автопродление |
| `PP_RENEWAL_INTERVAL_MIN` | `60` | период цикла автопродления, мин |
| `PP_RENEWAL_LEAD_HOURS` | `24` | за сколько часов до конца периода списывать |
| `PP_RENEWAL_MAX_ATTEMPTS` | `5` | неудачных списаний до отвязки карты |

Секреты ЮKassa в клиент не отдаются и в репозитории не хранятся.

## ЮKassa: интеграция

* Аутентификация — HTTP Basic `shopId:secretKey`; вызовы `POST /payments`
  (checkout) и `POST /refunds` (возврат) через `urllib.request` (SDK не нужен).
* Идемпотентность checkout/возврата — заголовок `Idempotence-Key` (= `order_id`).
* «Заказ» у ЮKassa = платёж: `provider_order_id == provider_payment_id` для
  событий `payment.*`; для `refund.*` `provider_payment_id` — id возврата,
  `payment_id`/`provider_order_id` — id исходного платежа.
* **Автопродление**: фоновый цикл billing (`run_renewals`, интервал
  `PP_RENEWAL_INTERVAL_MIN`) списывает сохранённый способ оплаты
  (`POST /payments` + `payment_method_id`, без confirmation — безакцептно)
  за `PP_RENEWAL_LEAD_HOURS` до конца периода; продление применяет
  штатный вебхук `payment.succeeded` (встык к текущему периоду). Ошибка
  списания → ретраи до `PP_RENEWAL_MAX_ATTEMPTS`, затем карта отвязывается
  (`saved_payment_method_id = NULL`) и подписка истекает до Free.
  Отмена (`cancel_at_period_end`) исключает подписку из выборки —
  `POST /payments/subscription/cancel|resume` управляют этим флагом.
  Для ПЕРВОГО сохранения карты нужен `YUKASSA_SAVE_PAYMENT_METHOD=1`
  (активация сохранения способов оплаты у мерчанта ЮKassa).
* Ключей в среде нет → `UnconfiguredProvider`: checkout/возврат отвечают 503 с
  понятным текстом. «Тестового подтверждения» оплаты в сервисе нет.

## Локальный запуск

```bash
pip install -r requirements.txt
export PP_AUTH_URL=http://127.0.0.1:8121
export PP_DATA_DIR=$PWD/data
export YUKASSA_SHOP_ID=... YUKASSA_SECRET_KEY=... YUKASSA_WEBHOOK_SECRET=...
uvicorn payments_app.main:app --port 8122
```

Docker (в стеке сервис называется `billing`):

```bash
docker build -t pp-billing .
docker run -p 8122:8122 \
  -e PP_AUTH_URL=http://auth:8121 \
  -e DB_URL=postgresql://pp_user:pp_secret@postgresql:5432/prepress_saas \
  -e YUKASSA_SHOP_ID=... -e YUKASSA_SECRET_KEY=... -e YUKASSA_WEBHOOK_SECRET=... \
  -v billing-data:/srv/billing/data pp-billing
```

## Тесты

```bash
python -m pytest tests -q                                  # SQLite (по умолчанию)
PP_TEST_DB_URL=postgresql://… python -m pytest tests -q    # та же сюита на PostgreSQL
```

57 тестов: тарифы и checkout, вебхук (подпись опциональна, сверка объекта
у провайдера в т.ч. на продакшн-провайдере),
идемпотентность и продление от конца периода, триал → Free → Pro,
отмена/возобновление, возврат (owner/admin; «в обработке» → вебхук), изоляция
тенантов, отсутствие legacy `/confirm`, чек ЮKassa (`receipt`, ADR-3) и
`save_payment_method`, реальный HTTP-канал ЮKassa на локальном
заглушечном сервере (`tests/test_yookassa_http.py`).

## Осталось (вне объёма этой задачи)

* Реальные `YUKASSA_SHOP_ID` / `YUKASSA_SECRET_KEY` / `YUKASSA_WEBHOOK_SECRET`
  в секрет-менеджере прод-контура + регистрация URL вебхука в личном кабинете
  ЮKassa (в compose пока плейсхолдеры `test_shop`/`test_secret`).
* Автоплатежи: цикл списаний реализован — остаётся внешнее: активация
  сохранения способов оплаты у мерчанта ЮKassa + `YUKASSA_SAVE_PAYMENT_METHOD=1`
  (иначе карты не сохраняются и `saved_payment_method_id` пуст).
* Чеки/фискализация (`receipt`) — по требованиям мерчанта.
* Регулярная сверка (reconciliation) `orders`/`transactions` с выпиской ЮKassa
  (для неё уже есть `GET /payments/transactions`).
* Rate-limit на checkout/refund и алерты по метрикам оплат (System Design §6).
