# 04. Сервисы и API «Препресс-Планер»

**Статус: актуален на 2026-09-07 (HEAD bed533e)**

Документ описывает четыре FastAPI-сервиса в `services/`: назначение, порты, переменные окружения, полные таблицы маршрутов, модель данных, зависимостях, безопасность, контракт «клиент ↔ сервис» и целевой контракт. Все утверждения — со ссылками на код.

## 1. Обзор

| Сервис | Пакет | Порт | В прод-стеке | Потребляется клиентом | Основание |
|---|---|---|---|---|---|
| converter | `converter_app` v0.2.0 | 8120 | да | да (AI/CDR/EPS → SVG) | `services/converter/converter_app/main.py:48-50` |
| auth | `auth_app` v0.2.0 | 8121 | да | да (аккаунт/сессии) | `services/auth/auth_app/main.py:275-276` |
| payments | `payments_app` v0.1.0 | 8122 | да | да (подписка Pro) | `services/payments/payments_app/main.py:126` |
| license | `license_app` v0.1.0 | не задан | **нет** | **нет** | `services/license/license_app/main.py:17`, `README.md:18` |

Развёртывание: `deploy/docker-compose.yml` (converter/auth/payments + nginx-web), альтернативный локальный стек — `services/docker-compose.yml`. Контейнеры: `deploy-{converter,auth,payments,web}-1` (`deploy/README.md:60-62`). Тома: `converter-data`, `auth-data`, `payments-data` (`deploy/docker-compose.yml:95-98`).

### 1.1 Локальный запуск и проверка

| Действие | Команда | Источник |
|---|---|---|
| Установка зависимостей | `pip install -r requirements.txt` (в каталоге сервиса) | `services/auth/README.md:57`, `services/converter/requirements.txt` |
| Запуск сервиса | `uvicorn <pkg>.main:app --port <8120\|8121\|8122>` | `services/auth/README.md:57-60`, `Dockerfile`-строки `CMD` |
| Обязательные env при запуске | auth — `PP_AUTH_SECRET`; payments — `PP_AUTH_URL` | `auth/main.py:52-54`, `payments/main.py:40-42` |
| Тесты сервисов | `python -m pytest services/{converter,auth,payments,license}/tests -q` (интерпретатор `cam_pipeline\venv\Scripts\python.exe`) | `README.md:56-63` |
| Тесты в CI | `python -m pytest services/converter/tests -q` и `services/license/tests -q` | `.github/workflows/ci.yml:47-54` |
| Пробы живого стека | `curl -s http://193.233.193.12:812{0,1,2}/healthz`, `curl -sI http://193.233.193.12:8081/` | `docs/HANDOFF.md:150-157` |

## 2. converter (:8120)

**Назначение.** Конвертация закрытых форматов AI/CDR/EPS в SVG/PDF движками Inkscape и Ghostscript; асинхронные задачи + статика результатов.

**Переменные окружения** (`services/converter/converter_app/main.py:1-13, 28-37`, `Dockerfile:22-24`):

| Переменная | По умолчанию | Назначение |
|---|---|---|
| `PP_DATA_DIR` | `<сервис>/data` | каталог данных (out/, jobs/); в докере `/srv/converter/data` |
| `PP_JOB_STORE` | `memory` | `memory` (память процесса) или `file` (JSON-файлы, общий том) |
| `PP_JOB_TTL_HOURS` | `24` | TTL задач и результатов файловой очереди |
| `PP_MAX_MB` | `50` | лимит размера загружаемого файла |
| `PP_INKSCAPE` | авто-поиск | путь к Inkscape (`convert.py:35-42`) |
| `PP_GHOSTSCRIPT` | авто-поиск | путь к Ghostscript (`convert.py:59-86`) |

В `PP_JOB_STORE=memory` TTL-чистки нет — `sweep()` реализован, но фоновый поток запускается только в `FileJobQueue` (`jobs.py:128-148, 106-117`).

**Маршруты:**

| Метод | Путь | Тело запроса | Ответ | Ошибки |
|---|---|---|---|---|
| GET | `/healthz` | — | `{status:"ok", engines:{inkscape,ghostscript}, job_store}` | — |
| POST | `/convert` | `multipart/form-data`: `file` (файл) + `target` = `svg`\|`pdf` | `200 {job_id}` (12 hex-символов) | `422` «Целевой формат: svg или pdf»; `400` «Формат `<ext>` не поддерживается: допустимы .ai, .cdr, .eps»; `400` «Файл больше 50 МБ — конвертация не выполняется» |
| GET | `/convert/{job_id}` | — | `{status: pending\|running\|done\|error, result_url, error}` | `404` «Задача не найдена» |
| GET | `/data/...` | — | статика каталога `PP_DATA_DIR` (`/data/out/<job_id>/result.svg\|pdf`) | `404` |

Ссылки: `/healthz` — `main.py:79-89`; `/convert` — `main.py:92-124` (проверки `99, 102-107, 114-119`, `job_id` — `jobs.py:78`); `/convert/{id}` — `main.py:127-139`; статика — `main.py:143`.

**Модель данных/хранение.** Задача: `job_id`, `status`, `result_path`, `error`, `log`, `created_at/updated_at` (`jobs.py:28-59`). Файлы: `out/<id>/result.<ext>`, `out/<id>/work/input.<ext>`, `work/log.txt`, `work/mid.pdf` (`main.py:53-77`, `convert.py:149, 209`); при `file` — `jobs/<id>.json` с атомарной записью tmp + `os.replace` (`jobs.py:154-177`). Загрузка сохраняется как `out/_upload_<hex8><ext>` (`main.py:110-113`) и удаляется воркером в `finally` (`main.py:72-76`).

**Зависимости.** FastAPI + uvicorn + python-multipart (`requirements.txt`), в образе — apt-пакеты `inkscape`, `ghostscript`, `fonts-dejavu` (`Dockerfile:9-13`). Движки вызываются подпроцессом с файловым stdio (`convert.py:94-103`); Ghostscript — с `-dSAFER` (`convert.py:211-213`).

**Безопасность (что есть / чего нет).** Аутентификации нет ни на одном маршруте; лимит размера проверяется **после** полной записи файла на диск (`main.py:112-119`); magic-байты не проверяются (только расширение, `main.py:100-107`); параллелизм не ограничен (поток на запрос, `main.py:121-123`); таймаутов у движков нет; статика `/data` отдаёт весь `PP_DATA_DIR`, включая `work/` с копией исходника и `jobs/*.json` (`main.py:143`); контейнер работает от root (`Dockerfile` — без `USER`). Подробнее — `SECURITY.md`, раздел 2.

## 3. auth (:8121)

**Назначение.** Аккаунты email+пароль, серверные сессии (opaque-токены), сброс пароля, лимит устройств 1/1; внутренний `verify` для payments.

**Переменные окружения** (`services/auth/auth_app/main.py:24-31, 52-59, 170-181`):

| Переменная | По умолчанию | Назначение |
|---|---|---|
| `PP_AUTH_SECRET` | — | обязателен, ≥16 символов; **для подписи не используется**, нужен для запуска (`main.py:52-54`) |
| `PP_DATA_DIR` | `<сервис>/data` | каталог БД (`auth.db`) |
| `PP_TOKEN_TTL` | `720` | срок сессии, часы (30 дней) |
| `PP_RESET_TTL` | `30` | срок кода сброса, минуты |
| `PP_SMTP_HOST/PORT/USER/PASSWORD/FROM` | — (`PORT` 587) | почта для сброса пароля |
| `PP_SMTP_SSL` | пусто | `1` — сразу TLS (порт 465) |

**Маршруты:**

| Метод | Путь | Тело/заголовки | Ответ | Ошибки |
|---|---|---|---|---|
| POST | `/auth/register` | `{email(3..254), password(6..128), device_id(1..128)}` | `{token, user:{id,email,created_at}}` | `409` «Email уже зарегистрирован»; `422` «Некорректный email» |
| POST | `/auth/login` | `{email, password(1..128), device_id}` | `{token, user}` | `401` «Неверный email или пароль»; `422` email |
| POST | `/auth/logout` | `Authorization: Bearer <token>` | `{ok:true, user_id}` | `401` «Требуется токен» / «сессия не найдена» / «сессия истекла» |
| GET | `/auth/me` | Bearer | `{user:{sub,email,device_id}}` | `401` |
| GET | `/auth/devices` | Bearer | `{devices:[{device_id,current,created_at,expires_at}], limit:1}` | `401` |
| POST | `/auth/verify` | Bearer (внутренний вызов payments) | `{sub, email}` | `401` |
| POST | `/auth/forgot` | `{email}` | `{ok:true, dev_code?, dev_hint?}` | `422` email |
| POST | `/auth/reset` | `{email, code(6), new_password(6..128)}` | `{ok:true}` | `404` «Пользователь не найден»; `400` «Неверный или истёкший код» |
| GET | `/healthz` | — | `{status, service:"auth", db, sessions:"server-side", device_limit:1, smtp, reset_ttl_min}` | — |

Ссылки: модели запросов — `main.py:239-259`; `register` — `299-313`; `login` — `316-329`; `logout` — `332-340`; `me` — `343-345`; `devices` — `348-366`; `verify` — `369-378`; `forgot` — `381-406`; `reset` — `409-427`; `healthz` — `430-435`.

**Модель данных/хранение.** SQLite `PP_DATA_DIR/auth.db` (`main.py:47-50`) с таблицами: `users(id, email UNIQUE, password_hash, created_at)`, `sessions(token_hash PK, user_id, device_id, created_at, expires_at)` + индекс `idx_sessions_user`, `reset_codes(email, code_hash, created_at, expires_at, used)` (`main.py:78-105`). Том `auth-data` (`deploy/docker-compose.yml:52-53`). Пароли — PBKDF2-HMAC-SHA256, 200 000 итераций, соль, `hmac.compare_digest` (`main.py:110-125`); токен — `secrets.token_urlsafe(32)`, в БД только sha256 (`main.py:128-148, 151-165`); код сброса — 6 цифр, в БД sha256 без соли (`main.py:208-234`).

**Ключевые правила.** Политика 1/1: при выдаче новой сессии все прежние удаляются (`main.py:136-148`), лимит отражён в ответе `/auth/devices` (`limit: 1`, `main.py:366`). Сброс пароля отзывает все сессии (`main.py:425-426`). Несуществующий email в `forgot` не раскрывается — ответ всегда `ok` (`main.py:389-396`).

**Безопасность (что есть / чего нет).** Есть: хеширование паролей, opaque-токены без хранения в открытом виде, реальный отзыв сессий, валидация email, отсутствие SQL-инъекций (только параметризованные запросы). Нет: rate limiting (ни на login, ни на reset), подтверждения email, ограничений попыток подбора 6-значного кода, `docs_url=None` (в проде открыты `/docs` и `/openapi.json`), TLS. Критично: при пустом `PP_SMTP_HOST` (а также при любой ошибке отправки письма) `POST /auth/forgot` возвращает сам код сброса (`dev_code`) в ответе — захват аккаунта (`main.py:390-405`; `SECURITY.md` К-1).

## 4. payments (:8122)

**Назначение.** Подписка Pro: тарифы, заказы, подтверждение оплаты (заглушка), вебхук провайдера (заглушка). Токены проверяются живым вызовом auth.

**Переменные окружения** (`services/payments/payments_app/main.py:17-21, 40-43`):

| Переменная | По умолчанию | Назначение |
|---|---|---|
| `PP_AUTH_URL` | — (обязателен) | адрес auth; в докере `http://auth:8121` |
| `PP_DATA_DIR` | `<сервис>/data` | каталог БД (`payments.db`) |
| `PP_PUBLIC_BASE` | пусто | публичный адрес сервиса — база для `url` заказа, иначе `url: null` |

**Тарифы** (`main.py:48-51`): `month` — 990 ₽ / 30 дней, «Pro на месяц»; `year` — 9 900 ₽ / 365 дней, «Pro на год».

**Маршруты:**

| Метод | Путь | Тело/заголовки | Ответ | Ошибки |
|---|---|---|---|---|
| POST | `/payments/checkout` | Bearer; `{plan(1..16)}` | `{order_id(16 hex), plan, title, amount_rub, status:"pending", url, hint}` | `422` «Тариф: month или year»; `401` недействительный токен; `503` auth недоступен |
| POST | `/payments/orders/{order_id}/confirm` | Bearer | `{ok:true, order_id, plan, until}` | `404` «Заказ не найден»; `409` «Заказ уже оплачен» / «Статус заказа: …»; `401`/`503` |
| POST | `/payments/webhook` | `{order_id}` (без подписи) | `{ok:true, order_id, until}` или `{ok:true, already:true}` | `422` «Нет order_id»; `404` «Заказ не найден» |
| GET | `/payments/subscription` | Bearer | `{plan, pro, until}` | `401`/`503` |
| GET | `/payments/plans` | — (токен не проверяется, хотя клиент его посылает) | `[{plan, title, amount_rub}]` | — |
| GET | `/healthz` | — | `{status, service:"payments", db, plans}` | — |

Ссылки: `verify_token` — `main.py:86-109` (HTTPError → `401`, URLError/Timeout/OSError → `503`); `checkout` — `146-164`; `confirm` — `167-201`; `webhook` — `204-235`; `subscription` — `238-244`; `plans` — `247-250`; `healthz` — `253-256`.

**Модель данных/хранение.** SQLite `PP_DATA_DIR/payments.db` (`main.py:35-38`) с таблицами `orders(id, user_id, plan, amount_rub, status pending|paid|cancelled, created_at, paid_at)` + индекс `idx_orders_user` и `subscriptions(user_id PK, plan, until, updated_at)` (`main.py:60-81`). Том `payments-data`. Продление считается от конца активной подписки, иначе от текущего момента (`main.py:184-190, 219-225`).

**Зависимости.** FastAPI + uvicorn + pydantic; HTTP-вызов auth — стандартной библиотекой `urllib.request` с таймаутом 8 с (`main.py:28-29, 91-98`).

**Безопасность (что есть / чего нет).** Есть: проверка токена через auth (отзыв сессии виден сразу), привязка заказа к `user_id` (чужой заказ → `404`, `main.py:170-174`), идемпотентность вебхука по статусу `paid` (`main.py:215-216`). Нет: платёжного провайдера (оплата — заглушка), подписи и аутентификации вебхука, rate limiting, TLS. Любой зарегистрированный пользователь может провести `checkout → confirm` и получить Pro без оплаты (`SECURITY.md` К-4).

## 5. license (не входит в прод-стек)

**Назначение.** Сервис лицензий (ключи, активации, подписки, офлайн-токены HMAC) — **в `deploy/docker-compose.yml` отсутствует и клиентом не вызывается** (`README.md:18`, `SECURITY.md` раздел 2). Порт в `Dockerfile`/коде не зафиксирован — запускается вручную.

**Маршруты** (`services/license/license_app/main.py`):

| Метод | Путь | Тело | Ответ | Ошибки |
|---|---|---|---|---|
| POST | `/license/activate` | `{machine_id, key?}` | результат `licensing.activate` (trial/key/expired/invalid + `offline_token`) | `422` «machine_id обязателен» |
| POST | `/license/validate` | `{machine_id}` | результат `licensing.validate` | `422` |
| GET | `/license/entitlements/{machine_id}` | — | результат `licensing.validate` | — |
| POST | `/webhooks/stripe` | `{event, machine_id, period_days=30}` | `{ok, until}` при `invoice.paid`, иначе `{ok, handled:false}` | — |
| POST | `/webhooks/apple` | `{receipt}` | `{ok:true, detail:"Ресивер принят (валидация — в проде)"}` | — |
| GET | `/admin/keys` | — | список ключей | — |
| POST | `/admin/keys` | `{key?, max_devices=3}` | `{key, max_devices}` | — |
| GET | `/health` | — | `{ok:true}` | — |

**Модель данных.** SQLAlchemy, URL из `PP_LICENSE_DB` (по умолчанию `sqlite:///<services/license>/license.db`, `main.py:14`); таблицы `devices`, `license_keys`, `activations`, `subscriptions` (`license_app/models.py:18-52`). Офлайн-токен — `base64url(payload).base64url(HMAC-SHA256)`, грэйс 30 дней (`license_app/crypto.py:10-64`).

**Безопасность.** Ни один маршрут не требует аутентификации, включая `/admin/keys` и вебхуки; секрет подписи по умолчанию — публичная константа `dev-secret-change-me` (`crypto.py:77-79`); валидации Apple-ресивера нет (`main.py:81-85`). См. `SECURITY.md`, раздел 3.

## 6. Контракт «клиент ↔ сервис»

| Потребитель | Сервис | Базовый адрес | Заголовки | Обработка ошибок на клиенте |
|---|---|---|---|---|
| `ConverterApi.convertToSvg` | converter | desktop: `PP_CONVERTER_URL`, дефолт `http://193.233.193.12:8120`; web: `''` → относительные пути | `multipart/form-data`, поле `file` (имя `import<ext>`), поле `target=svg` | `ConverterException` с русским текстом: разбор `detail` из JSON, `NetworkException` → «Сервис конвертации недоступен…», таймаут → «Сервер конвертации не отвечает…» (`converter_api.dart:56-59, 117-140, 167-200`) |
| `ConverterServer` | converter | тот же адрес | GET `/healthz` (проба) | `probe()` → `false`; ошибка запуска — текст в UI (`converter_server.dart:37-48`, `server_launch_io.dart:64-77`) |
| `AuthApi` | auth | desktop: `PP_AUTH_URL`, дефолт `…:8121`; web: относительные пути | `POST` JSON; `Authorization: Bearer <token>` для `logout/devices` | `ApiException` (текст из `detail`), таймауты 8 с → «Сервер авторизации не отвечает.», сеть → «Сервер авторизации недоступен. Проверьте сеть.» (`account_client.dart:196-318`) |
| `PaymentsApi` | payments | desktop: `PP_PAYMENTS_URL`, дефолт `…:8122`; web: относительные пути | `Authorization: Bearer <token>` на всех вызовах, включая `/payments/plans` | те же два сообщения для оплаты (`account_client.dart:321-399`) |
| `AccountGatewayHttp.purchase` | payments | — | `checkout` → `orders/{id}/confirm` | пустой `order_id` → `ApiException('Сервер не вернул order_id')` (`account_client.dart:185-193`) |
| `LicenseClient` | license | `serverUrl` = `null` (передаётся в `LicenseController`) | — | при `null` сеть не используется — локальный триал 15 дней (`license_client.dart:44-77`, `main.dart:35-40`) |

Логика выбора адреса: `envOrDefault(key, fallback)` на desktop читает `Platform.environment`, а на web **всегда возвращает `''`**, поэтому fallback не применяется и адреса становятся относительными (`platform/env_io.dart:8-11`, `platform/env_web.dart:6`, `platform/env.dart:11-12`). Транспорт: `dart:io` на desktop, `dart:html.HttpRequest` (XHR) на web (`platform/http.dart:11-12`, `platform/http_impl_web.dart:86-124`).

## 7. Версионирование и совместимость

- Версии приложений FastAPI объявлены как `0.2.0` (converter, auth), `0.1.0` (payments, license) — `main.py`-строки из таблицы §1. **Версионирования URL нет**: пути (`/convert`, `/auth/*`, `/payments/*`) не содержат версии.
- Обратная совместимость обеспечивается аддитивными изменениями: клиент читает только нужные поля ответа (`account_client.dart:48-55, 71-84`) и игнорирует неизвестные.
- Контракт конвертера продублирован в docstring клиента (`converter_api.dart:1-10`) и повторяет ответы сервера (`main.py:127-139`); рассинхронизация возможна при добавлении статусов — клиент отвергает неизвестный статус сообщением «Неизвестный статус задачи от сервера» (`converter_api.dart:159-161`).
- Схема БД создаётся идемпотентно при старте (`CREATE TABLE IF NOT EXISTS` — `auth/main.py:78-105`, `payments/main.py:60-81`); миграций (Alembic и т.п.) нет — при изменении схемы требуется ручное вмешательство.
- `deploy/build_bundle.ps1:20-22` пакует **только** `services/converter`, `services/auth`, `services/payments` — license в бандл не попадает.

## 8. Целевой контракт (что должно быть)

| Требование | Текущее состояние | Где зафиксировано |
|---|---|---|
| Аутентификация converter (`/convert`, `/data`) — токен или приватная сеть | отсутствует полностью | `SECURITY.md` раздел 2; `docs/specs/08_security.md` |
| Лимиты: размер — до записи на диск, magic-байты, таймауты движков, ограничение параллелизма | лимит по расширению и после записи, параллелизм не ограничен | `SECURITY.md` раздел 2 |
| Rate limiting на `/auth/login`, `/auth/reset`, `/convert` | отсутствует во всех сервисах | `SECURITY.md` К-5 |
| Код сброса не возвращается в ответе (при отсутствии SMTP — `503`), код ≥8 символов, лимит попыток | при пустом SMTP возвращается `dev_code`; 6 цифр без лимита попыток | `SECURITY.md` К-1; `auth/main.py:390-405` |
| Подпись и аутентификация вебхука; реальный платёжный провайдер до выдачи Pro | вебхук без подписи, `confirm` выдаёт Pro без оплаты | `SECURITY.md` К-4; `payments/main.py:167-235` |
| TLS/HTTPS и закрытые порты (единый origin :8081) | весь трафик по http, 8120/8121/8122 открыты в интернет | `SECURITY.md` К-3; `deploy/README.md:63-70` |
| Закрыть `/docs` и `/openapi.json` в проде | открыты на всех сервисах | `SECURITY.md` раздел 3 |
| Не-root пользователь в контейнерах, закреплённые версии зависимостей | все 4 образа от root, версии не закреплены | `SECURITY.md` раздел 2 |
| Серверный энфорсмент Pro (сейчас гейтинг клиентский) | Pro гейтится редактируемым `state/entitlement.json` | `SECURITY.md` раздел 2 |
| Решение судьбы `services/license` (auth на `/admin/keys`, подпись вебхуков) | сервис не развёрнут, маршруты без auth, дефолтный секрет | `SECURITY.md` раздел 3 |

План устранения (фазы 1–2) и полный перечень находок — `SECURITY.md`, разделы 1–2 и 5; детальная модель угроз и требования — `docs/specs/08_security.md` (документ пишется параллельно; на момент подготовки этого файла каталог `docs/specs` наполнялся).
