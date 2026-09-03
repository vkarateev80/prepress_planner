# Лицензионный сервер (license)

FastAPI: триал 15 дней, активация лицензионных ключей по machine-id,
подписки Pro, офлайн-токены, webhooks Stripe/Apple.

## API

- `POST /license/activate` `{machine_id, key?}`
  → без ключа: триал 15 дней (однократно); с ключом: активация (лимит
  устройств). Ответ: `{status: trial|active|expired|invalid, expires_at,
  offline_token}`.
- `POST /license/validate` `{machine_id}` → `{pro, until, trial_days_left}`.
- `GET /license/entitlements/{machine_id}` — то же.
- `POST /webhooks/stripe` `{event: "invoice.paid", machine_id, period_days}`
  — продление подписки.
- `POST /webhooks/apple` `{receipt}` — приём ресивера (валидация — в проде).
- `GET /admin/keys`, `POST /admin/keys` `{key?, max_devices}` — выпуск ключей.

Офлайн-токен: `base64url(json).base64url(HMAC-SHA256)`, валиден до `until`,
грэйс 30 дней с даты выдачи. Серверное время — источник истины.

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

## Переменные окружения (см. .env.example)

`PP_LICENSE_SECRET`, `PP_LICENSE_DB`, `STRIPE_SECRET`, `APPLE_*`.

