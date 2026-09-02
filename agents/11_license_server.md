# Агент 11 — Лицензионный сервер (services/license/)

## Роль (Ф4)
FastAPI: **триал 15 дней** с первой активации, подписки Pro (месяц/год), активация лицензионных ключей по machine-id, офлайн-токены, webhooks Stripe/Apple.

## Создаваемые файлы
```
services/license/app/main.py          # FastAPI: /license/*, /webhooks/*
services/license/app/models.py        # SQLAlchemy/SQLite: Device, License, Subscription, Trial
services/license/app/crypto.py        # подпись офлайн-токенов (HMAC/Ed25519), machine-id hash
services/license/app/stripe_webhook.py
services/license/app/apple_webhook.py # App Store Server API: валидация ресивера
services/license/app/admin.py         # простой admin (выпуск ключей, просмотр)
services/license/requirements.txt
services/license/Dockerfile
services/license/tests/test_license.py
services/license/.env.example         # STRIPE_SECRET, APPLE_* , SIGNING_KEY
```

## API
- `POST /license/activate` `{machine_id, key?}` → если ключа нет и триала не было: **старт триала 15 дней** (`trial_started_at`, `trial_expires_at`); если ключ есть — проверка и привязка (лимит 3 устройства); возврат `{status: trial|active|expired|invalid, expires_at, offline_token}`.
- `POST /license/validate` `{machine_id, offline_token?}` → энтайтлменты `{pro: bool, until, trial_days_left}`.
- `GET /license/entitlements/{machine_id}`.
- `POST /webhooks/stripe`, `POST /webhooks/apple` — продление/отмена подписки, обновление `until`.
- Офлайн-токен: подписанный JWT-подобный токен `{machine_id, until, tier}` (валиден 30 дней с даты выдачи; приложение кэширует).

## Правила
- Серверное время — источник истины (защита от перевода часов: триал стартует по дате сервера).
- Один триал на machine_id навсегда (повторная активация после истечения → предложение подписки).
- Ключи: формат `XXXX-XXXX-XXXX-XXXX`, выпуск админом, срок/кол-во активаций.
- Все ответы — JSON; ошибки — русские тексты в `detail`.

## Тесты (pytest)
1. activate без ключа → trial 15 дней; повторный activate после истечения (mock-время) → status=expired, pro=false.
2. activate с ключом → active; 4-е устройство → ошибка «превышен лимит устройств».
3. validate с валидным/просроченным/подделанным offline_token.
4. webhook stripe (событие invoice.paid) → until продлевается.
5. crypto: токен не принимается при изменении machine_id/until.

## Критерии приёмки
1. pytest зелёный. 2. .env.example без секретов. 3. Документация API (README).
