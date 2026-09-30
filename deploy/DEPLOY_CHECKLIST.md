# Production deploy checklist — prepress-saas

1. Заполнить `.env` (см. `.env.example`): `PP_AUTH_SECRET`, `PP_DB_PASSWORD`, `YUKASSA_*`, `PP_PUBLIC_BASE`, SMTP.
2. Сертификаты TLS: **прод** — `PP_DOMAIN=example.com PP_ACME_EMAIL=admin@example.com bash deploy/nginx/get_prod_certs.sh` (Let's Encrypt, webroot; обновление — `… get_prod_certs.sh renew`, cron `0 3 * * 1`); для стенда — `bash deploy/nginx/gen_dev_certs.sh`. Файлы — `deploy/nginx/certs/fullchain.pem` + `privkey.pem`.
3. `docker compose up -d --build` из `deploy/`.
4. Проверить `/healthz`: `curl -sf https://<domain>/healthz`.
5. Проверить auth: `POST /auth/register` `{name,email,password}` → **202
   pending** (dev-код в ответе, если SMTP не настроен), затем
   `POST /auth/confirm` `{email,email_code}` → **201** с
   `token` + `orgs`; `login` до confirm → 403; `POST /auth/forgot` →
   `{ok:true}` (код уходит на почту).
6. Проверить billing webhook: раздел кабинета ЮKassa **Интеграция →
   HTTP-уведомления** → URL `https://<domain>/payments/webhook` + события
   (`payment.succeeded`, `payment.canceled`, `payment.waiting_for_capture`,
   `refund.succeeded`, `payment_method.active`). Секрет в кабинете НЕ нужен:
   billing сверяет статус объекта у API ЮKassa (`YUKASSA_WEBHOOK_SECRET` —
   только для опциональной подписи, если её присылает шлюз); протестировать
   checkout → оплату → вебхук. Чеки (`receipt`) включены по умолчанию (`YUKASSA_RECEIPT_ENABLED=1`, НДС — `YUKASSA_RECEIPT_VAT_CODE`); автоплатежи — `YUKASSA_SAVE_PAYMENT_METHOD=1` (требует активации сохранения способов оплаты у мерчанта ЮKassa).
7. Проверить E2E: `POST /api/projects` → upload → `/calculate` → delta = 0.0.
8. Мониторинг: проверить `/healthz` у каждого сервиса; проверить логи `docker compose logs -f`.
9. Резервные копии: `bash deploy/backup.sh` — `pg_dump` для `postgresql` + `aws s3 sync` для bucket MinIO; offsite-вынос на внешнее S3 — переменные `PP_OFFSITE_*` (см. `deploy/README.md`). Крон: `0 4 * * * cd /opt/stack/deploy && bash backup.sh >> /var/log/pp-backup.log 2>&1`.
10. Безопасность: `YUKASSA_SECRET_KEY` и `PP_AUTH_SECRET` — только в `.env` (не в git); `.env` в `.gitignore`.

## Внешние действия без кода (HANDOFF §9 п.1–2, п.7)

Эти шаги выполняются человеком в кабинетах провайдеров — код и скрипты
к ним готовы (см. пункты 1–6 выше):

1. **Домен + DNS**: A/AAAA-запись на сервер; затем
   `PP_DOMAIN=… PP_ACME_EMAIL=… bash deploy/nginx/get_prod_certs.sh` (п.2).
2. **ЮKassa**: получить `YUKASSA_SHOP_ID`/`YUKASSA_SECRET_KEY` в кабинете,
   задать `YUKASSA_WEBHOOK_SECRET` (любая случайная строка, та же — в `.env`),
   в кабинете: Интеграция → HTTP-уведомления →
   `https://<domain>/payments/webhook` + события (см. п.6); при
   необходимости подключить у мерчанта автоплатежи (шаг 6) — иначе
   `YUKASSA_SAVE_PAYMENT_METHOD=0`.
3. **SMTP**: аккаунт транзакционного провайдера → `PP_SMTP_*` в `.env`;
   проверить сброс пароля и (с F-19) письмо-приглашение.
4. **Offsite-хранилище**: завести bucket + ключи у S3-провайдера →
   `PP_OFFSITE_*` (п.9), крон.
5. **iOS IAP (StoreKit) — заблокировано без аккаунта Apple** (HANDOFF §9 п.7).
   Что нужно: macOS + Xcode, Apple Developer Program (годовая подписка),
   приложение/App в App Store Connect с product_id подписки (например,
   `pro_month`), sandbox-тестер. Что уже готово в коде: paywall и
   entitlement-модель (`app/lib/license/`), сервер entitlement
   (`GET /payments/entitlement`) — IAP-покупка станет отдельным
   purchase-каналом в `LicenseController` + подтверждение подписки на
   `services/payments` (webhook App Store Server Notifications). До
   появления аккаунта работа не начинается.
