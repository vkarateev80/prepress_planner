# API (control plane) «Препресс-Планер»: проекты, файлы, версии (ADR-5, N-4).
# Зависимости: fastapi/pydantic/uvicorn + stdlib (SigV4 и HTTP — urllib);
# psycopg2 — только для DB_URL=postgresql://.
FROM python:3.12-slim

WORKDIR /srv/api
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY api_app ./api_app

ENV PP_DATA_DIR=/srv/api/data
RUN mkdir -p "$PP_DATA_DIR"

EXPOSE 8100
# env (задаётся в compose/секрет-менеджере, секреты — не в образе):
#   PP_AUTH_URL                  — адрес auth (обязателен, http://auth:8121)
#   DB_URL                       — postgresql://… (иначе SQLite в PP_DATA_DIR)
#   PP_DATA_DIR                  — каталог SQLite/api.db
#   PP_BILLING_URL               — адрес billing (entitlement-гейтинг)
#   CONVERTER_URL                — адрес конвертера (внутренний, http://converter:8120)
#   DOMAIN_WORKER_URL            — адрес domain-worker (следующая фаза)
#   OBJECT_STORAGE_ENDPOINT      — S3-совместимый endpoint (http://minio:9000)
#   OBJECT_STORAGE_PUBLIC_ENDPOINT — внешний endpoint для presigned URL
#   OBJECT_STORAGE_BUCKET        — bucket (prepress-saas)
#   OBJECT_STORAGE_ACCESS_KEY / OBJECT_STORAGE_SECRET_KEY — ключи доступа
#   PP_MAX_MB                    — лимит размера файла (50)
#   PP_PRESIGN_TTL               — TTL presigned GET (300 с)
CMD ["uvicorn", "api_app.main:app", "--host", "0.0.0.0", "--port", "8100"]
