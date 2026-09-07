# Лицензионный сервер (license)

FastAPI: триал 15 дней, активация лицензионных ключей по machine-id, подписки,
офлайн-токены, webhooks Stripe/Apple. Хранилище — SQLite через SQLAlchemy
(`PP_LICENSE_DB`, по умолчанию `sqlite:///<каталог сервиса>/license.db`).

> **Статус на 2026-09-07: сервис НЕ входит в прод-стек.** Его нет в
> `deploy/docker-compose.yml`, и клиент `app` его не вызывает: в приложении
> `LicenseClient` работает как локальная офлайн-заглушка (триал 15 дней на
> устройстве), а Pro-доступ даёт связка auth+payments. Dockerfile сервиса
> экспонирует порт 8121 (тот же, что у auth) — в общий стек он не включён.
>
> Все маршруты (включая `/admin/keys` и вебхуки) **без аутентификации и
> подписи**; секрет по умолчанию — публичная константа `dev-secret-change-me`
> (`crypto.py`) — см. разделы 2–3 `SECURITY.md` в корне репозитория.

## API

- `POST /license/activate` `{machine_id, key?}`
  - без ключа: триал 15 дней (однократно на устройство); при действующем
    триале — повторная выдача токена; после истечения — `status: expired`;
  - с ключом: проверка ключа и лимита устройств (`max_devices`), подписка
    продлевается на 365 дней от максимума(сейчас, текущий конец).
  - Ответ: `{status: trial|active|expired|invalid, expires_at, offline_token,
    ...}`.
- `POST /license/validate` `{machine_id}` → `{pro, until, trial_days_left}`.
- `GET /license/entitlements/{machine_id}` — то же, что validate.
- `POST /webhooks/stripe` `{event: "invoice.paid", machine_id, period_days=30}`
  — продление подписки (`invoice.paid`); прочие события → `{handled: false}`.
  Подпись Stripe не проверяется.
- `POST /webhooks/apple` `{receipt}` — ресивер принимается и возвращается
  `ok`; реальная валидация (App Store Server API) — вне scope MVP.
- `GET /admin/keys`, `POST /admin/keys` `{key?, max_devices=3}` — выпуск
  ключей формата `XXXX-XXXX-XXXX-XXXX` (без неоднозначных символов), без
  аутентификации.
- `GET /health` → `{ok}`.

Офлайн-токен: `base64url(payload).base64url(HMAC-SHA256)`, payload — JSON
`{machine_id, until, tier, iat}`; валиден до `until`, грэйс 30 дней от `iat`.
Серверное время — источник истины.

## env

| Переменная | По умолчанию | Назначение |
|---|---|---|
| `PP_LICENSE_SECRET` | `dev-secret-change-me` | Секрет подписи токенов (сменить в проде!) |
| `PP_LICENSE_DB` | `sqlite:///<сервис>/license.db` | URL БД (SQLAlchemy) |

## Запуск

```bash
pip install -r requirements.txt
set PP_LICENSE_SECRET=...    # подпись токенов
uvicorn license_app.main:app --port 8121
```

## Тесты

```bash
python -m pytest tests -q
```
