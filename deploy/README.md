# Комплект развёртывания «Препресс-Планер» SaaS

Единый стек на одном хосте: PostgreSQL, MinIO (S3-совместимое хранилище),
`api` (проекты и файлы), `auth`, `billing` (ЮKassa), `converter`, nginx (TLS,
единый origin) и статика Flutter Web. Внутренние порты наружу не публикуются
(ADR-6); состав и переменные — `deploy/docker-compose.yml`, `.env.example`.

| Компонент | Внутри сети | Снаружи |
|---|---|---|
| nginx (edge, TLS, статика SPA) | `web:443` | **`:443`** (80 → 301) |
| api (проекты/файлы: гибрид S3+PostgreSQL) | `api:8100` | — (через `/api`, `/files`, `/reports`) |
| auth (организации/роли, сессии, SMTP) | `auth:8121` | — (через `/auth`) |
| billing (ЮKassa checkout/webhook/entitlement) | `billing:8122` | — (через `/payments`) |
| converter (AI/CDR/EPS → SVG/PDF, ADR-7) | `converter:8120` | — (только сервер-к-серверу) |
| PostgreSQL (метаданные, состояния, подписки) | `postgresql:5432` | — |
| MinIO (объекты: исходники, SVG/PDF, отчёты) | `minio:9000` | — (presigned `/s3/`) |
| domain-worker (Dart VM, `packages/core`) | `domain-worker:8101` | — |

Сертификаты TLS: положите `fullchain.pem` и `privkey.pem` в `deploy/nginx/certs/`
(Let's Encrypt/certbot либо dev-сертификат) — иначе nginx не поднимется.

## Содержимое
- `docker-compose.yml` — полный стек (postgresql, minio, api, auth, billing,
  converter, domain-worker, web) — одна сеть, томá данных;
- `nginx/pp-web-tls.conf` — конфиг edge-nginx (TLS 443, SPA, прокси `/api
  /files /reports /s3 /auth /payments /convert /healthz`, лимиты тела и
  rate-limit на upload/download);
- `nginx/pp-web.conf` — прежний dev-конфиг без TLS (историческая совместимость);
- `.env.example` — шаблон переменных (`PP_AUTH_SECRET`, SMTP, ЮKassa,
  `PP_DB_PASSWORD`, ключи объектного хранилища и лимиты API);
- `install_new_server.sh` — первичная настройка нового Ubuntu (root);
- `web/` — сюда кладётся статика `flutter build web` (собирается скриптом);
- `build_bundle.ps1` / `build_bundle.sh` — сборка единого архива.

## Как развернуть новый сервер

**1) Собрать web-версию и бандл (на машине разработки):**
```powershell
# из app/:  flutter build web
powershell -ExecutionPolicy Bypass -File deploy\build_bundle.ps1
```
Получится `pp-new-server-stack.tar.gz` в корне репозитория.

**2) Загрузить и распаковать на новом сервере:**
```bash
scp pp-new-server-stack.tar.gz root@<новый-IP>:/
ssh root@<новый-IP>
tar xzf pp-new-server-stack.tar.gz
cd stack/deploy && bash install_new_server.sh
```
Скрипт: ставит Docker + compose (при отсутствии), генерирует `.env`
(секрет `PP_AUTH_SECRET` случайный), поднимает стек (`docker compose up -d
--build`) и ждёт здоровье сервисов.

**3) Открыть:** `https://<домен>/` — единый origin (443). Внутренние порты
(8100/8101/8120/8121/8122/5432/9000) наружу не публикуются; в dev-стеке
`services/docker-compose.yml` они опубликованы для отладки.

## Перенос данных (если нужно)
Тома: `pg-data` (метаданные проектов/файлов, подписки), `minio-data`
(объекты: исходники, конвертированные SVG/PDF, отчёты), `converter-data`
(очередь и staging конвертера), `auth-data`, `billing-data`, `api-data`,
`domain-data`. Перенос с текущего сервера:
```bash
# на старом сервере (директории /opt/pp-converter и /opt/pp-services):
#   docker run --rm -v converter-data:/data -v $PWD:/backup alpine tar czf /backup/converter.tgz -C /data .
# …аналогично auth-data, payments-data; на новом: распаковать в те же тома.
```
Настройка SMTP (`PP_SMTP_*` в `.env`) для прода **обязательна**: код сброса
пароля отправляется только по почте и никогда не возвращается в ответе
`/auth/forgot`. Без SMTP код создаётся в БД, но письмо не уходит (в логах —
ошибка доставки); для локальных проверок используйте SMTP-заглушку
(например, MailHog). База auth обновляется автоматически при старте и
**сохраняет данные** (миграция legacy → организации/роли, см.
`services/auth/README.md`); перед обновлением прода сделайте копию тома
`auth-data`.

## ВАЖНО: адреса в клиенте (ADR-6)

Зашитые IP старого VPS (`http://193.233.193.12:8120/8121/8122`) **удалены** из
клиентской логики: на web адреса пусты → вызовы идут относительными путями
того же origin (`/convert`, `/auth`, `/payments`, `/api/...` через edge nginx),
на desktop по умолчанию локальный сервер разработки
(`http://127.0.0.1:8120/8121/8122`) и переопределение env
`PP_CONVERTER_URL` / `PP_AUTH_URL` / `PP_PAYMENTS_URL`. Публичный IP в
`pp-web-tls.conf` больше не встречается (проверка: `grep -rn 193.233.193.12 app/lib services`).

## Проекты и файлы в облаке (`api`, ADR-5)

`api` (внутренний 8100) хранит проекты/файлы организации: метаданные и версии —
в PostgreSQL, blobs ≤ 50 МБ — в S3-совместимом MinIO по ключу
`org/{org_id}/project/{project_id}/file/{file_id}/{version}/{sha256}/{name}`.
Публичного bucket нет: скачивание — поток через `GET /api/files/{id}/download`
либо короткоживущий presigned URL (`/s3/<bucket>/...` через edge, TTL 300 с).
Подробности, схема таблиц и контракты — `services/api/README.md`.

## Проверка после установки
```bash
curl -k https://127.0.0.1/                      # index.html (SPA, 200)
curl -k https://127.0.0.1/healthz               # nginx-edge: {"status":"ok",…}
curl -k -o /dev/null -w '%{http_code}\n' https://127.0.0.1/auth/devices           # 401
curl -k -o /dev/null -w '%{http_code}\n' https://127.0.0.1/payments/subscription  # 401
curl -k -o /dev/null -w '%{http_code}\n' https://127.0.0.1/api/projects          # 401
# внутри сети (с хоста стека):
docker compose exec api python -c "import urllib.request as u; print(u.urlopen('http://127.0.0.1:8100/healthz').read().decode()[:300])"
docker compose ps
```

Проверка схемы и хранилища: `GET /api/projects` под Bearer-токеном создаёт
проект (`POST /api/projects {"name": "Проверка"}`), затем загрузка файла:

```bash
curl -k -X POST https://127.0.0.1/api/projects -H "Authorization: Bearer $TOKEN" \
     -H 'Content-Type: application/json' -d '{"name":"Проверка"}'
curl -k -X POST https://127.0.0.1/api/projects/$PID/files \
     -H "Authorization: Bearer $TOKEN" -F file=@fixtures/petlya.svg
# закрытые форматы (AI/CDR/EPS) конвертируются сервером (ADR-7):
curl -k -X POST https://127.0.0.1/api/projects/$PID/files \
     -H "Authorization: Bearer $TOKEN" -F file=@fixtures/quadroring.ai
```
Ответ содержит `file_id`, `storage_key` (с префиксом `org/<org_id>/project/...`)
и `checksum`; метаданные — в БД (`docker compose exec postgresql psql -U pp_user
-d prepress_saas -c 'select id, org_id, name, file_type, size_bytes from files'`),
объект — в MinIO (консольный порт закрыт; проверяется `GET
/api/files/{file_id}/download`).
