# Billing-сервис «Препресс-Планер»: ЮKassa (checkout/webhook/entitlement, ADR-3).
# Зависимости: fastapi/pydantic + stdlib; psycopg2 — только для DB_URL=postgresql://.
FROM python:3.12-slim

WORKDIR /srv/payments
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY payments_app ./payments_app

ENV PP_DATA_DIR=/srv/payments/data
RUN mkdir -p "$PP_DATA_DIR"

EXPOSE 8122
# env (задаётся в compose/секрет-менеджере, секреты — не в образе):
#   PP_AUTH_URL             — адрес auth (в docker http://auth:8121), обязателен
#   DB_URL                  — postgresql://… (иначе SQLite в PP_DATA_DIR)
#   PP_DATA_DIR             — каталог SQLite/payments.db
#   YUKASSA_SHOP_ID         — shopId ЮKassa
#   YUKASSA_SECRET_KEY      — секретный ключ ЮKassa (Basic auth)
#   YUKASSA_WEBHOOK_SECRET  — секрет проверки HMAC-SHA256 подписи вебхука
#   YUKASSA_API_URL         — по умолчанию https://api.yookassa.ru/v3
#   PP_TRIAL_DAYS           — триал в днях (15)
#   PP_PRO_MONTH_PRICE_RUB / PP_PRO_YEAR_PRICE_RUB — цены (990 / 9900)
#   PP_PUBLIC_BASE          — публичный origin для return_url (ADR-6, 443)
CMD ["uvicorn", "payments_app.main:app", "--host", "0.0.0.0", "--port", "8122"]
