# Микросервис оплаты «Препресс-Планер» (заглушка до подключения провайдера).
FROM python:3.12-slim

WORKDIR /srv/payments
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY payments_app ./payments_app

ENV PP_DATA_DIR=/srv/payments/data
RUN mkdir -p "$PP_DATA_DIR"

EXPOSE 8122
# PP_AUTH_SECRET (общий с auth) задаётся в docker-compose / окружении.
CMD ["uvicorn", "payments_app.main:app", "--host", "0.0.0.0", "--port", "8122"]
