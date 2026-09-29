# Админ-панель «Препресс-Планер»: мониторинг бэкенда, аккаунты, доступы,
# подписки, read-only просмотр БД. Отдельный сервис (по решению владельца).
FROM python:3.12-slim

WORKDIR /srv/admin
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY admin_app ./admin_app

EXPOSE 8130
# env (задаётся в compose/секрет-менеджере, секреты — не в образе):
#   AUTH_URL       — адрес auth (в k8s http://auth:8121), обязателен
#   DB_URL         — postgresql://… (иначе SQLite по AUTH_DB_PATH — только тесты)
#   AUTH_DB_PATH   — путь к auth.db (в k8s /srv/auth/data/auth.db, PVC ro)
CMD ["uvicorn", "admin_app.main:app", "--host", "0.0.0.0", "--port", "8130"]
