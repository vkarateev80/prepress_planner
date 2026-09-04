# Сервис авторизации (auth)

Аккаунты email+пароль для «Препресс-Планер»: регистрация, вход, проверка
токена. Токены — HMAC-SHA256 (stateless), подпись проверяет и сервис оплаты
(общий секрет `PP_AUTH_SECRET`). Пароли — pbkdf2_hmac (200k итераций).
Хранилище — SQLite (`PP_DATA_DIR/auth.db`).

## API

- `POST /auth/register` `{email, password}` → `{token, user}`
- `POST /auth/login` `{email, password}` → `{token, user}`
- `POST /auth/logout` (Bearer) → `{ok}`
- `GET /auth/me` (Bearer) → `{user: {sub, email}}`
- `GET /healthz` → статус

## env

| Переменная | По умолчанию | Назначение |
|---|---|---|
| `PP_AUTH_SECRET` | — (обязателен) | Секрет подписи токенов (≥ 16 символов); общий с payments |
| `PP_DATA_DIR` | `<сервис>/data` | Каталог БД |
| `PP_TOKEN_TTL` | `720` | Срок токена, часы (30 дней) |

## Локальный запуск

```bash
pip install -r requirements.txt
set PP_AUTH_SECRET=...
uvicorn auth_app.main:app --port 8121
```

## Docker

```bash
docker build -t pp-auth .
docker run -p 8121:8121 -e PP_AUTH_SECRET=... -v auth-data:/srv/auth/data pp-auth
```

## Тесты

```bash
python -m pytest tests -q
```
