# Production deploy checklist — prepress-saas

1. Заполнить `.env` (см. `.env.example`): `PP_AUTH_SECRET`, `PP_DB_PASSWORD`, `YUKASSA_*`, `PP_PUBLIC_BASE`, SMTP.
2. Сертификаты TLS: `deploy/nginx/certs/fullchain.pem` + `privkey.pem` (certbot или провайдер; для стенда — `bash deploy/nginx/gen_dev_certs.sh`).
3. `docker compose up -d --build` из `deploy/`.
4. Проверить `/healthz`: `curl -sf https://<domain>/healthz`.
5. Проверить auth: `POST /auth/register` → 201 с `token` + `orgs`.
6. Проверить billing webhook: зарегистрировать `https://<domain>/payments/webhook` в ЮKassa; протестировать checkout + webhook с `YUKASSA_WEBHOOK_SECRET`.
7. Проверить E2E: `POST /api/projects` → upload → `/calculate` → delta = 0.0.
8. Мониторинг: проверить `/healthz` у каждого сервиса; проверить логи `docker compose logs -f`.
9. Резервные копии: `bash deploy/backup.sh` — `pg_dump` для `postgresql` + `aws s3 sync` для bucket MinIO (см. `deploy/README.md`).
10. Безопасность: `YUKASSA_SECRET_KEY` и `PP_AUTH_SECRET` — только в `.env` (не в git); `.env` в `.gitignore`.
