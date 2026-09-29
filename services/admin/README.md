# Сервис админ-панели (admin)

Отдельный сервис (решение владельца): веб-панель для мониторинга бэкенда и
управления аккаунтами, доступами, подписками и просмотра БД.

## Доступ

Вход — обычный `POST /auth/login`, но панель видна **только** пользователям
с ролью **owner/admin в системной организации** — первой по `created_at`
(как выбрано владельцем: «роль admin/owner»). Новые пользователи становятся
owner только своей личной организации и в панель не попадают. Роли
`member`/`viewer`/`admin` в системной организации назначаются из самой
панели (через auth API).

## Возможности

- **Обзор**: healthz всех сервисов стека + счётчики (пользователи, сессии,
  проекты, заказы, Pro).
- **Аккаунты**: поиск, активные сессии, отзыв сессий, удаление аккаунта
  (каскад: сессии/членства/коды; нельзя удалить owner системной организации).
- **Доступы**: члены системной организации, добавление/приглашение с ролями,
  удаление членства.
- **Подписки**: выдача Pro (+30/365 дней) и отзыв прямой правкой
  `subscriptions`+`entitlements`; **возврат реальных средств — только в
  кабинете ЮKassa**.
- **Заказы**: список статусов.
- **База данных**: read-only просмотр whitelisted-таблиц PostgreSQL
  (plans, projects, files, file_versions, reports, orders, transactions,
  subscriptions, entitlements).

## API

`POST /admin/api/login` — вход; остальные `/admin/api/*` — Bearer.
Подробная таблица — в докстринге `admin_app/main.py`.

## env

| Переменная | Назначение |
|---|---|
| `AUTH_URL` | адрес auth (в k8s `http://auth:8121`) |
| `DB_URL` | `postgresql://…` (в тестах — путь к SQLite) |
| `AUTH_DB_PATH` | путь к `auth.db` (в k8s `/srv/auth/data/auth.db`, PVC auth) |

## Локальный запуск и тесты

```bash
pip install -r requirements.txt
export AUTH_URL=http://127.0.0.1:8121 DB_URL=/tmp/admin.db AUTH_DB_PATH=…
uvicorn admin_app.main:app --port 8130
python -m pytest tests -q   # 9 тестов
```

Веб-маршрут: `https://<домен>/admin/` (nginx location `/admin` → `:8130`).
