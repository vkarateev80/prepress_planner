# Микросервис авторизации «Препресс-Планер».
FROM python:3.12-slim

WORKDIR /srv/auth
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY auth_app ./auth_app

ENV PP_DATA_DIR=/srv/auth/data
RUN mkdir -p "$PP_DATA_DIR"

EXPOSE 8121
# PP_AUTH_SECRET задаётся в docker-compose / окружении (обязателен).
CMD ["uvicorn", "auth_app.main:app", "--host", "0.0.0.0", "--port", "8121"]
