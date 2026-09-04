# Сервис авторизации (auth)

Аккаунты email+пароль для «Препресс-Планер»: регистрация, вход, выход,
проверка токена, сброс пароля, список устройств.

**Сессии — серверные**: таблица `sessions`, токены opaque (в БД — только
sha256). Выход реально отзывает сессию; **лимит устройств 1/1** — новый вход
с другого `device_id` вытесняет прежнюю сессию. Payments проверяет токены
внутренним вызовом `POST /auth/verify`. Пароли — pbkdf2_hmac (200k итераций).
Хранилище — SQLite (`PP_DATA_DIR/auth.db`).

## API

- `POST /auth/register` `{email, password, device_id}` → `{token, user}`
- `POST /auth/login` `{email, password, device_id}` → `{token, user}`
  (лимит 1/1: старые сессии пользователя отзываются)
- `POST /auth/logout` (Bearer) → `{ok}` (сессия отзывается)
- `GET /auth/me` (Bearer) → `{user: {sub, email}}`
- `GET /auth/devices` (Bearer) → `{devices: [{device_id, current, ...}], limit: 1}`
- `POST /auth/verify` (Bearer) — внутренний вызов payments → `{sub, email}`
- `POST /auth/forgot` `{email}` → `{ok}`; без SMTP в ответе ещё `dev_code`
- `POST /auth/reset` `{email, code, new_password}` → `{ok}` (сессии отзываются)
- `GET /healthz` → статус, device_limit, smtp

## Сброс пароля

`/auth/forgot` создаёт одноразовый код (6 цифр, TTL `PP_RESET_TTL`, по
умолчанию 30 мин) и отправляет его на email через SMTP (`PP_SMTP_HOST` +
STARTTLS 587 или SSL 465 при `PP_SMTP_SSL=1`). Если SMTP не настроен —
**dev-режим**: код возвращается в ответе (`dev_code`), чтобы проверить поток.

## env

| Переменная | По умолчанию | Назначение |
|---|---|---|
| `PP_AUTH_SECRET` | — (обязателен) | Секрет (≥ 16 символов) |
| `PP_DATA_DIR` | `<сервис>/data` | Каталог БД |
| `PP_TOKEN_TTL` | `720` | Срок сессии, часы (30 дней) |
| `PP_RESET_TTL` | `30` | Срок кода сброса, минуты |
| `PP_SMTP_HOST/PORT/USER/PASSWORD/FROM` | — | Почта для сброса (SMTP) |
| `PP_SMTP_SSL` | пусто | `1` = TLS сразу (порт 465) |

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
