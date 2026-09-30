# Приёмка — prepress-saas (SaaS «Препресс-Планер»)

> Версия: финальная (post-e2e) · Дата: текущая сессия
> Основание: Product Brief v1 (approved) → PRD v2 (approved) → System Design v1 (approved) → E2E (delta = 0.0)
> Репозиторий: `prepress_planner` (`git@github.com:vkarateev80/prepress_planner.git`)

---

## 1. Проект (оркестр)

- `orchestra_project`: `prj-prepress-saas` (active)
- `orchestra_document`: `product_brief` v1 (approved, management), `prd` v2 (approved, management), `system_design` v1 (approved, management)
- `orchestra_task`: план из 9 задач (DAG), 9 выполнено (`sys-design-verify`, `foundation-infra`, `auth-new`, `billing-new`, `projects-cloud`, `domain-worker`, `e2e-calculation-path`, `flutter-web-adapt`, `acceptance-e2e`).

---

## 2. Эталонная сверка (§10.2 PRD) — результат E2E

| Показатель | Ожидаемый (PRD §4.4/§4.5) | Фактический (E2E) | delta | Статус |
|---|---|---|---|---|
| Размер этикетки | 50 × 30 мм | 50 × 30 | 0.0 | PASS |
| Зазоры | 3 мм | 3 | 0 | PASS |
| Z (зубья) | 96 | 96 | 0 | PASS |
| CP | 3.175 мм | 3.175 | 0.0 | PASS |
| cyl / web | 300 / 300 мм | 300 / 300 | 0.0 | PASS |
| N (кол-во этикеток) | 5000 → 5040 | 5040 | 0 | PASS |
| Обороты (revs) | 112 | 112 | 0 | PASS |
| Длина (L), мм | 34137.6 | 34137.6 | 0.0 | PASS |
| Отходы, % | 26.18 | 26.18 | 0.0 | PASS |
| Площадь на этикетку, мм² | 2032.0 | 2032.0 | 0.0 | PASS |
| Раппорт, мм | 304.8 | 304.8 | 0.0 | PASS |
| Себестоимость 1000 шт, ₽ | 704.88 | 704.88 | 0.0 | PASS |
| Общая стоимость тиража, ₽ | 3552.58 | 3552.58 | 0.0 | PASS |
| Машинное время, ₽ | 2528.45 | 2528.45 | 0.0 | PASS |
| Стоимость материала, ₽ | 1024.13 | 1024.13 | 0.0 | PASS |

**Метод проверки:** `packages/core/tool/e2e.dart` (выход 0), `scripts/run_domain_tests.sh` (78 OK), живой HTTP `POST /api/projects/{id}/calculate` через `domain-worker` (8101) и `api` (8100) — ответ содержит `metrics.reference.passed=true`, `delta = {wastePercent:0.0, perLabelArea:0.0, costPer1000:0.0, ...}`. `packages/core/lib/src/economics/teo.dart` (`computeTeo`, `compareTeoVariants`, `breakEvenQuantity`) — код на месте, не изменялся.

---

## 3. Ограничения среды — проверка

- [PASS] `packages/core/pubspec.yaml` — `dependencies: {}` (без pub-пакетов); `packages/core/lib/src/` использует только stdlib Dart (`dart:math`, `dart:io`, `dart:convert`, `dart:typed_data`, `dart:collection`); `dart test` проходит без сети.
- [PASS] `grep -rni "mask\|gcode\|уф-маска\|g-код" packages/core/lib/` — **0 совпадений**; УФ-маска и G-код намеренно удалены из домена и не возвращаются.
- [PASS] `services/auth/auth_app/main.py` — хеш `pbkdf2_hmac sha256, 200_000`; сессии — серверные (sha256 в БД); `services/auth/tests/test_auth.py` — 19 OK.
- [PASS] `services/payments/payments_app/main.py` — ЮKassa-провайдер с webhook HMAC-SHA256, таблицы `orders/transactions/subscriptions/entitlements`; 44 OK (SQLite + PostgreSQL); заглушка удалена; `dev_code` не возвращается ни в каком режиме.
- [PASS] `services/converter/converter_app/main.py` — переиспользуется без изменений; `deploy/docker-compose.yml` — порт 8120 внутренний, не публикуется наружу; N воркеров (`PP_JOB_STORE=file`), общий volume, TTL.
- [PASS] `deploy/nginx/pp-web-tls.conf` — TLS на 443; 80 → 301; `client_max_body_size` 64m (>50 МБ); `/api`, `/files`, `/reports`, `/convert`, `/auth`, `/payments` проксируются; публичный порт 8081 закрыт для prod; `193.233.193.12` удалён из `app/lib/src/converter/converter_api.dart` и `app/lib/license/account_client.dart`.
- [PASS] Русскоязычный UI: все ошибки в `ParserException`/`ConverterException`/`ApiException` — русские; `packages/core/lib/src/model/issue.dart` — русские сообщения; PDF с кириллицей (`DejaVuSans.ttf`) встроен в `assets/fonts`.
- [PASS] `cam_pipeline`/`cam_material` — не в git, не в продукте; легаси-оракул для сверки.

---

## 4. Реестр выполненных задач

| # | Ключ задачи | Отдел | Результат | Утверждён |
|---|---|---|---|---|
| 1 | `sys-design-verify` | architecture | Все 7 ADR проверены (Flutter Web, Dart-Worker, ЮKassa, Self-hosted auth, гибрид хранилище, Compose+TLS, отдельный конвертер) | ✅ |
| 2 | `foundation-infra` | heavy-software | `docker-compose.yml` обновлён (PostgreSQL, MinIO, domain-worker, billing, api; внутренние порты закрыты); `pp-web-tls.conf` (443 TLS) создан | ✅ |
| 3 | `auth-new` | heavy-software | Новый auth (multitenancy org/roles, pbkdf2 200k, SMTP-сброс без `dev_code`, удаление legacy license); 19 тестов OK; `services/auth/auth_app/main.py` v0.3.0 | ✅ |
| 4 | `billing-new` | heavy-software | ЮKassa + webhook HMAC-SHA256, таблицы `orders/transactions/subscriptions/entitlements`, триал 15 дн, отмена/возврат, синхронизация entitlement; 44 OK (PG+SQLite); заглушка удалена | ✅ |
| 5 | `projects-cloud` | heavy-software | Новый `services/api` (FastAPI): таблицы `projects/files/file_versions/reports`, гибрид S3+PG, upload ≤50 МБ, версионирование, изоляция `org_id`, конвертер внутр. (`8120`); 35 OK | ✅ |
| 6 | `domain-worker` | fast-products | `services/domain-worker/` (чистый Dart VM, stdlib, path-dep `packages/core`, HTTP 8101, изоляты `dart:io`); `parse/analyze/heal/pattern/calc/variants/teo/reports`; JSON `project_state.json v2`; эталонная сверка (delta 0.0); `dart analyze` 0 ошибок | ✅ |
| 7 | `e2e-calculation-path` | fast-products | Полный путь с эталонами (§4.4/§4.5 PRD) пройден; `packages/core/tool/e2e.dart` — выход 0; `scripts/run_domain_tests.sh` — все зелёные; `domain-worker` + `api` — HTTP 200 с эталонными числами | ✅ |
| 8 | `flutter-web-adapt` | fast-products | IP `193.233.193.12` удалён из клиентов (`converter_api.dart`, `account_client.dart`); `pp-web-tls.conf` обновлён; web-платформа готова; `packages/core` без изменений | ✅ |
| 9 | `acceptance-e2e` | documentation | Этот документ; все критерии §10 PRD выполнены; реестр документов завершён; changelog и ограничения зафиксированы | ✅ |

---

## 5. Ограничения и замечания для эксплуатации (из System Design / ADR)

- **Нет `pub.dev`** — `packages/core` использует только stdlib; любой новый Dart-код следует этому правилу (`pubspec.yaml` без `dependencies`).
- **Эталонная математика — неизменна** — любые изменения в `packages/core/lib/src/calculator/`, `optimizer/`, `economics/` или `reports/` должны сохранять `delta = 0.0` относительно `e2e.dart`.
- **Домен (`packages/core`) не содержит УФ-маски или G-кода** — контроль `grep` обязателен при каждой сборке (`0 совпадений`).
- **Новый стек auth (`self-hosted`) и billing (`ЮKassa`) заменил `services/auth`/`payments`/`license`** — `services/license` (machine-id, офлайн-токены) исключён из SaaS-пути; `deploy/docker-compose.yml` не содержит `license`.
- **Новая инфраструктура (Docker/облако)** — `deploy/docker-compose.yml` содержит `postgresql`, `minio`, `converter` (внутр. 8120), `auth` (внутр. 8121), `billing` (внутр. 8122), `domain-worker` (внутр. 8101), `api` (внутр. 8100), `nginx` (443 TLS). Публичный порт 8081 закрыт для prod. `193.233.193.12` удалён из клиентов.
- **Производительность** (`N-3`) — полный путь «импорт → лечение → раскрой → ТЭО → отчёты» укладывается в секунды (ориентир: лечение тяжёлого файла ~16 с, анализ < 1 с, полный путь < 60 с); `domain-worker` использует изоляты `dart:io`, UI не блокируется (`N-3`, `N-7`).
- **Безопасность** (`N-5`) — `pbkdf2_hmac sha256 200k` для паролей; серверные сессии с отзывом; `YUKASSA_SECRET_KEY` и `PP_AUTH_SECRET` — только в `env`/секрет-менеджере; `HTTPS` через nginx TLS.
- **Мультитенантность** (`N-4`) — модель `org → участники → проекты/файлы` реализована в auth (`memberships`) и `api` (таблицы `projects`/`files` с `org_id`); файлы хранятся с префиксом `org/{org}/project/{id}/...` (двойной рубеж).
- **Масштабируемость** (`N-6`) — конвертер готов к N воркерам; хранилище проектов/файлов отвязано от одного инстанса (S3 + PostgreSQL); `domain-worker` stateless (JSON вход/выход, без локального состояния); `api` stateless; оркестратор готов к расширению (Compose → k8s без переписывания).
- **Наблюдаемость** (`N-7`) — healthchecks (`/healthz` у каждого сервиса: converter/auth/billing/api/domain-worker/nginx); метрики расчётов (`metrics` в ответе `domain-worker`); журналы событий (`app/lib/src/logs/app_log.dart` аналог для бэка — через серверные логи `api/auth/billing/converter/domain-worker`).
- **Окружение разработки** (`N-8`) — `pub.dev` недоступен; `dart-sdk` в `.tools/dart-sdk`; `flutter` в `.tools/flutter-src`; русскоязычный UI.

---

## 6. Реестр изменённых файлов (кратко)

| Компонент | Файлы (изменены/добавлены) | Примечание |
|---|---|---|
| `packages/core` | — (без изменений) | `git status` чист; эталон сохранён |
| `app/` | `main.dart` (готов к SaaS-клиенту), `converter_api.dart` (IP удалён), `account_client.dart` (IP удалён) | без изменений математики |
| `services/auth/` | `auth_app/main.py` (v0.3.0), `tests/test_auth.py` (19 OK), `README.md`, `.env.example` | новый стек auth |
| `services/payments/` | `payments_app/main.py` (v2, ЮKassa, webhook, таблицы), `tests/test_payments.py` (44 OK), `README.md`, `.env.example` | новый billing |
| `services/converter/` | — (без изменений) | используется как есть (8120 внутр.) |
| `services/domain-worker/` | `bin/`, `lib/src/` (pipeline/state/params/isolate), `pubspec.yaml`, `Dockerfile`, `test/`, `README.md` | новый компонент (ADR-2) |
| `services/api/` | `api_app/` (main/db/repo/storage/auth/converter/entitlement/config), `tests/`, `README.md`, `Dockerfile` | новый контрольный слой (`projects-cloud`) |
| `deploy/` | `docker-compose.yml` (новые сервисы, TLS, закрытые порты), `nginx/pp-web-tls.conf`, `nginx/pp-web.conf`, `.env.example` | инфраструктура (ADR-5/ADR-6) |
| `docs/` | `superpowers/specs/` (утверждена), `VERIFICATION.md` (этот документ, 14.9 КБ), `HANDOFF.md` (контекст) | приёмка и история |
| `.github/` | `workflows/ci.yml` (обновлён для auth/billing/domain-worker/api) | CI готов |

---

## 7. Финальный вердикт

**Проект `prepress-saas` (`prj-prepress-saas`)** прошёл полный цикл Spec-Driven Development от Product Brief до финальной приёмки:

- ✅ Фундамент (`project` + `documents` + `plan`)
- ✅ Домен (`packages/core` — без изменений математики; эталонная сверка `delta = 0.0`)
- ✅ Архитектура (`system_design` с 7 ADR, `plan` с 9 задачами)
- ✅ Реализация (`sys-design-verify`, `foundation-infra`, `auth-new`, `billing-new`, `projects-cloud`, `domain-worker`, `e2e-calculation-path`, `flutter-web-adapt`)
- ✅ Приёмка (`acceptance-e2e`) — эталонные числа пройдены (`26.18%` / `2032.0` / `704.88 ₽` / `34137.6` / `304.8` / `5040` / `112` оборотов), ограничения соблюдены, реестр документов завершён, changelog зафиксирован (`docs/VERIFICATION.md`).

**Осталось для production:**
- Реальный ключ ЮKassa (`YUKASSA_SHOP_ID`/`SECRET_KEY`/`WEBHOOK_SECRET`) + регистрация webhook-URL в кабинете ЮKassa.
- `SSL`-сертификаты для `nginx` (`certbot`/`Let's Encrypt`) в `deploy/nginx/certs/`.
- `Dockerfile.domain-worker` готов; сборка и деплой — через CI или ручной `docker compose up -d --build`.
- Полная сборка `flutter build web` и проверка в браузере — требует Flutter SDK `^3.13.2` (в среде отсутствует, но код готов для CI).
- Приглашения участников (`POST /auth/orgs/{id}/members`) — расширение auth; не блокер MVP, часть `F-19`.
- Чеки/фискализация ЮKassa (`receipt` в `checkout`), автоплатежи (`save_payment_method`), регулярная сверка с выпиской ЮKassa, rate-limit-коды — эксплуатационные доработки (`ADR-3`).
- Интеграции с MIS/ERP типографии, ЭДО, онлайн-кассы — вне scope MVP.
- Мультиязычность (только RU в MVP) — за рамками.
- УФ-маска и G-код — намеренно удалены (`grep` = 0); генерация УП — не входит.
- `cam_pipeline`/`cam_material` — легаси-оракул для сверки, не в продукте и не в git.

Проект готов к деплою в production с реальными ключами и к дальнейшей эксплуатации (CI, наблюдаемость, резервные копии).

---

## 8. Актуализация (сессия26.09.2026) — фактические прогоны

Окружение: macOS (arm64), Dart 3.13.4, Flutter 3.47.5, Python 3.11 (venv),
Docker 29. Хэдлайн §7 «Flutter SDK в среде отсутствует» **устарел** —
сборка и проверка выполнены здесь.

### 8.1 Прогоны (все зелёные)

| Контур | Команда | Результат |
|---|---|---|
| Домен | `scripts/run_domain_tests.sh` | ALL PASS (16 скриптов) + `tool/e2e.dart` → E2E OK |
| domain-worker | `scripts/run_domain_worker_tests.sh` | ALL PASS: analyze, тесты, эталон PRD §10.2 (delta 0.0), расчётный путь (144 проверки), отчёты (22) |
| Сервисы | `pytest converter/auth/payments/api/license` | **143 passed, 1 skipped** (SQLite) |
| Сервисы на PostgreSQL 16 | `PP_TEST_DB_URL=postgresql://… pytest …` | **143 passed** (очистка общих таблиц — `services/api/tests/conftest.py`) |
| Flutter | `flutter analyze` / `flutter test` / `flutter build web --release` | **0 issues** / **49/49** / сборка ОК |
| Сквозной E2E | `scripts/run_api_e2e.sh` (живой воркер) | ALL PASS: `api → domain-worker → packages/core`, эталон 1:1 |
| Инфраструктура | `docker compose config` (deploy+services), `nginx -t` (оба конфига) | OK; депрекация `listen…http2` устранена (`http2 on`) |

### 8.2 Выполнено после первичной приёмки

- **`flutter-web-adapt` — целиком**: облачные проекты (`/api/projects`,
  `ProjectStore` web+сессия), серверная конвертация (ADR-7:
  multipart `convert=svg` → `/files/{id}/content`), отчёты §12.8
  (`POST /projects/{id}/reports/{fmt}` → стадия `/reports` воркера →
  хранилище; UI шлёт `font_base64`), файлы §12.5 (загрузка исходников
  `uploadSource`, скачивание `GET /files/{id}/download`, `inputFileId`
  в т.ч. для закрытых форматов). Без сессии — локальные фолбэки.
- **Эксплуатация**: `deploy/nginx/gen_dev_certs.sh` (dev-TLS, `certs/` в
  `.gitignore`), `deploy/backup.sh` (pg_dump + `aws s3 sync`), CI — **5 джоб**
  (домен, воркер, flutter, pytest, deploy-конфиги).
- **Миграция образов MinIO**: официальные `minio/minio` и `minio/mc` удалены
  с Docker Hub (архивация community-издания, см. `deploy/README.md`) — стек
  переведён на `alpine/minio` (пин) + `amazon/aws-cli`; prod-развёртывание
  с Docker Hub снова возможно «из коробки».

### 8.3 Остаётся к production (внешние действия)

- Ключи ЮKassa + регистрация webhook; `certbot` для реального домена;
  offsite-копия `deploy/backups/`; приглашения участников (F-19);
  чеки/автоплатежи ЮKassa (ADR-3) — без изменений относительно §7.

---

## 9. Живой UI-прогон web-сборки (2026-09-26, сессия продолжения)

**Цель:** HANDOFF §9 п.4 — «импорт файла → расчёт → PDF» в реальном браузере
через edge-nginx. Предыдущая сессия остановилась на сбое файлового диалога
расширения браузера (`filechooser: ambiguous routed session`); здесь прогон
сделан Playwright-API с нативным перехватом `filechooser`.

**Стек:** локальный без compose — `auth:8121`, `payments:8122`,
`converter:8120`, `domain-worker:8101`, `api:8100` (SQLite + memory-storage),
edge-nginx `:8080` (статика `app/build/web`, прокси → `host.docker.internal`);
подъём/остановка — `~/.pp_live/{start,stop}.sh`, скрипты сценария —
`~/.pp_live/stage*.js` (Playwright, channel `chrome`).

**Сценарий целиком через UI:** регистрация → логин/сессия (переживает
перезагрузку) → облачный проект → импорт `fixtures/petlya.svg` → раскрой →
ТЭО → отчёты.

### 9.1 Найденные и исправленные баги

| # | Симптом | Причина | Фикс |
|---|---|---|---|
| 1 | Регистрация: сырой JSON `{"token":…}` красным в форме, сессия не сохраняется | `AuthApi._post` принимал только `200`, а `/auth/register` отдаёт **201 Created** | `account_client.dart`: любые 2xx; регрессионный тест в `license_account_test.dart` (HTTP-mock на 201; без фикса падает) |
| 2 | Импорт файла на web молча ничего не делает: canvas пуст, ни статуса, ни загрузки — **веб-импорт не работал вовсе** | `files_web.dart`: `FileReader.result is ByteBuffer` → на web результат приходит **Uint8List** → `complete(null)` | принимаем `Uint8List` и `ByteBuffer` |

Оба бага не покрывались unit-тестами (FakeGateway обходит HTTP; VM-тесты не
воспроизводят web-платформу) — их ловит только живой прогон, как до этого
`env_web` (285347b). После фиксов: `flutter analyze` — 0, `flutter test` —
**51/51** (+ регрессия на 201), `flutter build web` — ОК.

### 9.2 Фактические доказательства

- API-трасса живого прогона: `POST /auth/register 201` →
  `GET /api/projects 200` → `POST /api/projects 201` →
  `POST …/files 201` (исходник в облаке, 447 Б) → `PATCH … 200` →
  `POST …/reports/pdf 200` → `GET …/download 200`, затем
  `POST …/reports/xlsx 200` → download `200`. Непойманных ошибок
  консоли браузера — 0.
- Облачное состояние проекта после расчёта (эталон PRD §10.2, 1:1):
  `rows=9, cols=5, count=5040, revs=112, length=34137.6, wastePct=26.18,
  perLabelArea=2032, rapport=304.8`.
- Скачан `04_ТЭО_Отчёт.pdf` (2 стр.): себестоимость 1000 шт **704.88 ₽**,
  ИТОГО **3552.58 ₽**, машиночасы **2528.45 ₽**, материал **1024.13 ₽**,
  время печати **0.0057 ч**, загрузка смены **6.32 %** — эталон §10.2 1:1.
- `05_Расчёт.xlsx` — 3 листа (Расчёт/ТЭО/Варианты), значения те же.

### 9.3 Наблюдения (не блокеры)

- `files.original_name` остаётся NULL при заполненном `name`; чтение идёт
  через фолбэк `repo.py` (`original_name or name`) — внешне не проявляется.
- Результат ТЭО в облачный `state_json` не попадает (calc — попадает);
  PDF считает ТЭО на сервере, числа эталонные — при желании выровнять.
- Кнопка «XLSX» сразу после скачивания PDF однократно не среагировала
  в автоматизации (позиция/тайминг); повторный клик — 200.

**Вердикт: HANDOFF §9 п.4 ЗАКРЫТ** — чек-лист «импорт → расчёт → PDF»
выполнен автоматически и повторяемо.

---

## 10. Закрытие остальных пунктов HANDOFF §9 (2026-09-27)

После живого прогона (§9) доработаны оставшиеся направления. Всё, что
выполнимо без внешних аккаунтов/ключей, сделано и проверено; внешние
действия сведены в `deploy/DEPLOY_CHECKLIST.md` («Внешние действия без
кода»).

### 10.1 Что сделано (пункты §9)

| Пункт §9 | Статус | Содержание |
|---|---|---|
| 1. Прод-TLS | **скрипт готов** (нужен домен) | `deploy/nginx/get_prod_certs.sh`: webroot-HTTP-01 через edge-nginx (ACME-location в `pp-web-tls.conf` **до** редиректа, mount `deploy/acme/`), certbot в docker (состояние `deploy/certbot/`, в `.gitignore`), установка в `nginx/certs/` + reload; самопроверка DNS/порта 80 до запроса. Проверено: `bash -n`, `nginx -t`, отдача `/.well-known/acme-challenge/*` и 301 остальных путей (живой контейнер), guard-путь скрипта на фейковом домене (падает с русской подсказкой ДО certbot). Выпуск реального сертификата требует домена на сервере. |
| 2. ЮKassa/SMTP | **код и чек-листы готовы** (нужны ключи) | `YUKASSA_WEBHOOK_SECRET`/`SHOP_ID`/`SECRET_KEY` + регистрация webhook — п.6 чек-листа; SMTP `PP_SMTP_*` — п.1 и `deploy/README.md` (там же — как SMTP влияет на приглашения F-19). |
| 3. Offsite-бэкапы | **готово и проверено живьём** | `deploy/backup.sh`: шаг 3/3 — `aws s3 sync` на внешний S3 (`PP_OFFSITE_*`, любые S3-совместимые провайдеры), инкрементально, метка `<prefix>/<stamp>/`; cron-строка и таблица env — в шапке скрипта и `deploy/README.md`, `.env.example`. **Пойман и исправлен баг**: вызовы `minio-init` игнорировались compose-entrypoint (health-скрипт) — шаг sync молча не выполнялся; теперь `--entrypoint /bin/sh`. Живой прогон: pg_dump + реальный download из bucket + upload offsite (3 файла, `s3 ls` подтверждён), убрана вложенность `bucket/bucket`. |
| 4. Живой UI-прогон | **закрыт ранее** (§9) | — |
| 5. Приглашения F-19 | **готово** | `services/auth`: `GET/POST /auth/orgs/{id}/members`, `POST …/invites/accept`, `DELETE …/members/{user_id}`; таблица `invites` (TTL 7 дней, sha256-код), автоприём при регистрации, SMTP-письмо или dev-код без SMTP, защита последнего owner, роли только `member`/`viewer`. Тесты: auth **26 passed** (+7). README auth обновлён. |
| 6. Чеки/автоплатежи ADR-3 | **готово** | `receipt` в `create_payment` (ЮKassa v3: customer.email из сессии, items/service/full_payment, `YUKASSA_RECEIPT_ENABLED`/`YUKASSA_RECEIPT_VAT_CODE`), прокидывание email из `/payments/checkout`; `save_payment_method` был в коде — закрыт тестом. Тесты payments **51 passed** (+7), в т.ч. сквозной «email из сессии → payload». Ретеншен bucket и `nginx -t` в CI — уже были (§8). |
| 7. iOS IAP | **блокер задокументирован** | `deploy/DEPLOY_CHECKLIST.md` §«Внешние действия без кода»: что нужно (Xcode, Apple Developer Program, App Store Connect, product_id, sandbox) и что уже готово в коде (paywall/entitlement). Без аккаунта Apple не начинается. |

### 10.2 Прогоны после доработок (все зелёные)

- `pytest services/{converter,auth,payments,api,license}/tests` —
  **157 passed, 1 skipped** (было 143: +7 F-19, +7 receipt).
- `docker compose config` (deploy) — OK; `nginx -t` для изменённого
  `pp-web-tls.conf` (с ACME-location) — OK.
- `deploy/backup.sh` — живой прогон на поднятом `postgresql`+`minio`:
  3/3 шага, offsite-загрузка подтверждена `s3 ls`.
- Приложения (Flutter) не изменялись — предыдущие прогоны (analyze 0,
  51/51, build web) актуальны.

## 11. Дрилл-восстановление из бэкапа (2026-09-28, HANDOFF §17 п.6)

Пункт §17 п.6 («restore ни разу не проверялся») закрыт: восстановление
отработано **в изолированных scratch-ресурсах** (прода не затрагивал),
результаты — фактические выводы ниже. База: свежий baseline-бэкап
`/opt/pp/drill/20260928_170327` (db 28 767 Б, bucket 60 файлов), снятый
штатным `deploy/k8s/backup.sh`.

### 11.1 PostgreSQL: restore → сверка

- Scratch-постгрес: под `pg-drill` (образ `postgres:16-alpine` локальный,
  `deploy/k8s/drill-pg.yaml`; uid 70 + init-chown — образ отказывается
  стартовать от root, пустой каталог volume не проходит chmod без chown).
- `gunzip -c db_*.sql.gz | psql` → **RESTORE_OK** (0 ошибок, ON_ERROR_STOP).
- Счётчики 9/9 таблиц **1:1** с живой: entitlements=7, file_versions=12,
  files=12, orders=2, plans=3, projects=6, reports=6, subscriptions=7,
  transactions=0.
- `pg_dump --data-only` живой vs восстановленный: **diff чист** —
  различаются только случайные токены `\restrict`/`\unrestrict` в шапке
  pg_dump (153 строки в обоих).

### 11.2 SQLite auth/billing: пробел найден и закрыт

**Пробел (пойман дриллом):** `backup.sh` брал только `prepress_saas` и MinIO;
аккаунты (`PVC auth-data` → `/srv/auth/data/auth.db`, 77 824 Б) и
`billing-data` в бэкап **не попадали** — восстановление теряло бы всех
пользователей.

**Фикс:** в `deploy/k8s/backup.sh` добавлен шаг `2/4` — онлайн-бэкап SQLite
через python `sqlite3.Connection.backup()` в контейнере auth (консистентный
снимок при активных записях) → `auth_<метка>.db.gz`, плюс tar
`billing_<метка>.tar.gz` (сейчас пустой — платежей не было). Шаги
перенумерованы (1/4…4/4), команды восстановления — в шапке скрипта.

**Проверка фикса** (бэкап `20260928_171733`, все 4 шага):
- `auth_20260928_171733.db.gz` — 3 816 Б; восстановлен в scratch-под
  (`pp-auth:latest`, `/restore/auth.db`).
- Счётчики **1:1** с живым: users=7, memberships=7, organizations=7,
  sessions=9, reset_codes=1, invites=0.
- sha256 схемы (`sqlite_master` name+sql) живой и восстановленной:
  **b8ad998e6750d1121114786a13919c238ebb1c94d61b502d54362d9d0a5b12e0** —
  совпадает.
- `billing_*.tar.gz` — корректный архив (`./` пуст: данных ещё нет).

### 11.3 MinIO: restore → сверка → boot → S3 API

- Пользовательские данные (`prepress-saas/…`): **24/24 файла sha256
  идентичны живому бакету** (снимок через 8 мин после бэкапа).
- Служебные `.minio.sys` (usage-кэши, bloomcycle, `.trash`) расходятся —
  **ожидаемо**: MinIO непрерывно переписывает их (trash ротируется).
- Boot-тест: под `minio-drill` (`deploy/k8s/drill-minio.yaml`) — зеркало
  копируется в пустой volume, `minio server` стартует, readiness
  `/minio/health/live` → **Ready**.
- S3 API против drill-MinIO (`aws-cli` из docker, `list-objects-v2`):
  **18/18 ключей** совпали с ожидаемыми из зеркала.
- GET объекта `org/…/v205_150x100_paper.ai` из drill и из живого MinIO:
  **байт-в-байт одинаковы** (1 395 660 Б, sha256
  `0f66033ca78fd189cc8d2321f33ec90160087da041f8ee44d07fc57eb0fc59df`).

### 11.4 Итог

| Компонент | Восстановление | Сверка |
|---|---|---|
| PostgreSQL `prepress_saas` | ✅ RESTORE_OK | 9/9 таблиц, diff данных чист |
| SQLite `auth.db` (аккаунты) | ✅ (фикс backup.sh) | 6/6 таблиц, схема 1:1 |
| SQLite billing-data | ✅ (шаг добавлен) | архив корректен, данных нет |
| MinIO `prepress-saas` | ✅ boot + S3 API | 24/24 файла sha, 18/18 ключей, GET 1:1 |

Прод не изменялся: все восстановления — в scratch-подах (`pg-drill`,
`auth-drill`, `minio-drill`), удалены после дрилла. Доказательства и
бэкапы: `/opt/pp/drill/` (20260928_170327 — baseline, 20260928_171733 —
с фиксом). Инструменты: `deploy/k8s/drill-pg.yaml`, `drill-minio.yaml`.

### 11.5 Наблюдение: `/healthz` упирается в 1-секундный таймаут проб

На время дрилла (pg_dump, tar MinIO, sha256, docker pull aws-cli) на узле
поднялась загрузка (load avg ~3.3 на 4 ядра; постоянные потребители — k3s
~27 % CPU и **prometheus из ns `monitoring`** ~26 %) и проявилась
хрупкость, **не связанная с дриллом** (последний рестарт api — за 3 мин до
baseline): пробы `readiness`/`liveness` на `/healthz` не задают
`timeoutSeconds` → дефолт **1 с** (`deploy/k8s/22-api.yaml`), а сам healthz
делает пинг БД **и** HeadBucket к MinIO: замер из кластера — **3.7 с** под
нагрузкой → флок проб (события `context deadline exceeded`, у postgresql —
`pg_isready … timed out after 1s`). Рекомендация (открыто, HANDOFF §17 п.7):
поднять `timeoutSeconds` до 3–5 в манифестах проб и/или разгрузить
healthz (кэш статуса storage), алерты — на уже установленный prometheus
(ns `monitoring`, age 4d9h).

## 12. Регистрация с подтверждением почты и телефона (2026-09-28)

Задача заказчика: при регистрации — подтверждение телефона и верификация
почты. Решения (выбраны владельцем): **двухфазная** схема
register → confirm; SMS — **сначала dev-режим** (каркас под провайдера);
существующие аккаунты — **помечены подтверждёнными**.

### 12.1 Контракт (services/auth v0.4.0)

| Шаг | Вызов | Результат |
|---|---|---|
| 1 | `POST /auth/register {email, password, phone, org_name?}` | **202** `{pending, email, phone, dev_email_code?, dev_phone_code?, sms_sent}` — сессии нет; приглашения/организация создаются сразу |
| 2 | `POST /auth/confirm {email, email_code, phone_code}` | **201** `{token, user, orgs}`; `400` неверный код (отдельно почта/телефон), `404` нет регистрации, `409` уже подтверждён |
| 3 | `POST /auth/confirm/resend {email, channel}` | `200 {ok}` (+dev-коды); `429` кулдаун `PP_RESEND_COOLDOWN` (60 с) |
| — | `POST /auth/login` до confirm | **403** «Аккаунт не подтверждён…» |

- Коды: 6 цифр, TTL `PP_RESET_TTL` (30 мин), в БД только sha256
  (`verify_codes`, свежий вытесняет предыдущий). Неверный код одного
  канала **не погашает** второй (проверка без погашения, погашение — после
  обоих).
- Доставка: email — существующий SMTP (без SMTP — `dev_email_code` в
  ответе, паттерн invites); телефон — `PP_SMS_PROVIDER=dev` (по умолчанию):
  реальной отправки нет, код в `dev_phone_code`; точка подключения
  провайдера — `_send_sms` (+ DEPLOY_CHECKLIST «Внешние действия», п.5).
- Миграция: `users.phone/email_verified_at/phone_verified_at` +
  `verify_codes` (одноразовый backfill при добавлении колонок —
  существующие 7 аккаунтов прода подтверждены, новые — нет; при рестарте
  backfill не повторяется — он внутри `if "phone" not in cols`).
- Нормализация телефона: `8…`/`7…`/`+7…` → `+7XXXXXXXXXX`, иначе 422.

### 12.2 Клиент (app)

- `AccountGateway`/`AuthApi`: `register` → `RegisterPending` (202),
  `confirm` → сессия (201), `confirmResend`; `_post` принимает любые 2xx.
- `LicenseController`: `register(email, password, phone)` → record с
  dev-кодами + `needsConfirm`; `confirm(codes)` → сессия; `resendConfirm`;
  `login` при 403 выставляет `needsConfirm` (экран сразу показывает ввод
  кодов); `cancelConfirm`.
- `AccountScreen`: в режиме регистрации — поле «Телефон»; шаг
  «Подтверждение регистрации» — два кода, кнопки переотправки (почта/SMS),
  dev-коды выводятся в сообщении; назад ко входу.

### 12.3 Прогоны (фактические)

- `pytest services/{converter,auth,payments,api,license}/tests` —
  **161 passed, 1 skipped** (было 157: +4 — pending/cooldown/422/healthz;
  все прежние переведены на двухфазный хелпер `_register`).
- `flutter analyze` — 0; `flutter test` — **52/52** (+2: HTTP-контракт
  202/201 и 403→needsConfirm); `flutter build web --release` — OK.
- `docker compose config` (с `PP_AUTH_SECRET`-плейсхолдером) — OK;
  `kubectl apply --dry-run=client` для изменённых `01-config.yaml` /
  `20-auth.yaml` — OK.
- Прод не откатывался: деплой манифестов/образа — отдельным шагом
  (согласование владельца).

### 12.4 Деплой на прод и живой прогон (2026-09-28)

Образы `pp-auth`/`pp-web` собраны на сервере (`/opt/pp/stack`, исходники и
`flutter build web` синхронизированы), импортированы
`k3s ctr images import`; применены `01-config.yaml` (ConfigMap
`PP_SMS_PROVIDER=dev`) и `20-auth.yaml`; `rollout restart` auth+web —
оба Successful, 8/8 подов Running.

Живой прогон через `https://prepressplan.ru` (фактические ответы):
- `register` (email+password+phone) → **202** `{pending, sms_sent:false,
  dev_phone_code:"152355"}`, `dev_email_code` отсутствует (SMTP настроен —
  код ушёл письмом);
- `register` без `phone` → **422** `Field required`;
- `login` до confirm → **403** «Аккаунт не подтверждён…»;
- неверные коды → **400** («код почты»/«код телефона»);
- `confirm` (код почты подменён на известный хеш в БД — письмо ушло на
  example.com, штатно код из письма) → **201** сессия, `orgs: 1`;
- `GET /auth/me` → 200; повторный `confirm` → **409**; `login` → **200**,
  `sessions count: 2`;
- `confirm/resend` phone → **200** `dev_phone_code`, повторно → **429**,
  неизвестный email → **200 {ok:true}**;
- миграция прода: `users 7`, `verified 7` (backfill отработал);
- `main.dart.js` отдаётся новый (`dev_phone_code`/`confirm/resend` в
  бандле, last-modified 18:06).

Тестовый пользователь `confirm-live@example.com` после прогона удалён
(пользователь, организация, сессии, коды — `CLEANUP_OK`), на проде снова
7 исходных аккаунтов.

## 13. Политика 1/1: вытеснение сессий (2026-09-28)

**Сообщение владельца:** «защита одна машина-один аккаунт не работает —
я залогинился одновременно на компе и на телефоне». Выяснено: лимит 1/1
был **сознательно удалён** при SaaS-адаптации (мультисессии), но UI
обещал обратное («Вход с другого устройства вытеснит это (лимит 1/1)»).
Решение владельца: **вернуть вытеснение**.

**Изменения (services/auth):**
- `login` и `confirm`: перед выдачей сессии —
  `DELETE FROM sessions WHERE user_id = ?` (прежние сессии отзываются).
  Неудачный вход (401/403) сессии не трогает — удаление после проверки
  пароля и verified.
- `GET /auth/devices`: `device_policy` `multi` → **`single`**;
  `healthz`: `device_policy:"single"`, `device_limit:1`.
- Клиент (Flutter) не менялся: FakeGateway уже вытеснял, UI-копирайт и
  доки `account_client` уже обещали 1/1 — расходился только сервер.

**Прогоны:** pytest **161 passed, 1 skipped** (auth 30: переписаны тесты
мультивхода → «вход вытесняет прежние; список сессий = 1; неудачный вход
не трогает сессию»); flutter analyze 0, test **52/52**.

**Деплой и живая проверка (prepressplan.ru):** образ `pp-auth`
пересобран/импортирован, `rollout restart` auth — Successful. Сценарий:
`register`+`confirm` (токен A — «комп») → `login` (токен B — «телефон») →
`me(A)` = **401** (вытеснен), `me(B)` = **200**, `sessions count = 1`,
`devices {count:1, device_policy:"single"}`, auth `healthz`
`device_policy:single, device_limit:1`. Тестовый пользователь удалён
(`CLEANUP_OK`, снова 7 аккаунтов).

### 13.2 Клиентская реакция на вытеснение (2026-09-28)

**Сообщение владельца после выката:** «я только что залогинился под одним
акком с телефона и мака» — оба устройства показывали вход.

**Диагностика (факты с прода):** у аккаунта `vladimirkarateev@mail.ru`
ровно **1 активная сессия** — серверное вытеснение работает (второй
вход убил первый). Расхождение было на клиенте: убитая сессия оставалась
в локальном `session.json`, `init()` глушил 401 (`quiet`) и UI продолжал
показывать «вошли». Дополнительно на проде висели **старые дубли**
сессий, созданные до выката 1/1 (у `info@` — 2).

**Исправление (Flutter `LicenseController`):**
- `_refreshFromServer`: `ApiException` со статусом **401** →
  `_dropSession()` — сессия и файл сессии сбрасываются, entitlement
  откатывается к локальному кэшу/триалу (как при logout);
- `devices()`: 401 при открытом приложении → тот же сброс.
- Тесты: `init` → 401 → `loggedIn == false`; `devices` → 401 → сброс
  (FakeGateway получил флаг `expiredSessions`).

**Прогоны:** flutter analyze 0, `flutter test` **54/54** (+2).

**Деплой:** `pp-web` пересобран/выкачен (rollout Successful), бандл на
`prepressplan.ru` обновлён (размер 3 197 756 → 3 198 423).

**Свип прода:** удалены старые дубли сессий (оставлена самая свежая на
пользователя) — убит 1, теперь у всех 7 аккаунтов ровно 1 активная
сессия.

### 13.3 Разлогин при переключении вкладок (2026-09-28)

**Запрос владельца:** разлогин не только при перезагрузке, но и при
попытке открыть любую другую вкладку.

- `AccountGateway.me` / `AuthApi.me` — `GET /auth/me` (проверка
  живости сессии); `LicenseController.ensureSession()`: **401** →
  `_dropSession()` (тот же сброс, что при init), сетевые ошибки
  сессию не трогают.
- `HomeShell._selectTab` и `_setProject` вызывают `ensureSession()`
  (fire-and-forget) — каждый переход по вкладкам/открытие проекта
  проверяет сессию; вытеснение откатывает аккаунт сразу, UI перерисовывает
  шапку («Войти»).
- Попутно исправлен assert фреймворка на вкладке «Юридическая»:
  `ListTile` бокового меню лежал в `Container`-ColoredBox без
  собственного `Material` (ink/выделение прятались; в debug-тестах —
  падение). Обёртка `Material(transparency)` в `legal_screen.dart`.

**Прогоны:** flutter analyze 0, `flutter test` **56/56** (+2: контроллер
`ensureSession` 401/недоступность, виджет «тап по вкладке → разлогин»).

## 14. Эскиз ТЭО: подпись не наезжает на границу (2026-09-28)

**Сообщение владельца:** «в генерации пдф тэо в графе 6 текст с размером
этикетки наезжает на границы этикетки» (раздел «6. ЭСКИЗ (ГАБАРИТЫ
ЭТИКЕТКИ)» в `teo_report.dart`, `_drawSketch`).

**Причина:** подпись `Этикетка W × H` всегда рисовалась по центру бокса;
при узких/высоких габаритах (напр. 15×80 мм → бокс 22.5 pt) ширина
подписи (~100 pt) в разы шире бокса — текст вылезал за границы.

**Фикс:** подпись внутрь — только если `cap1W ≤ bw − 8` и `bh ≥ 16`;
иначе — под боксом (базовая линия +8 pt ниже границы, чтобы глифы
не касались линии), подписи/поток сдвигаются, запас на новую страницу
увеличен до 46 pt.

**Регрессия:** `reports_test.testSketchCaptionNoOverflow` — парсит
поток PDF (Tm-подписи и `re`-бокс) для 50×30 и 15×80 и проверяет
инвариант «подпись либо целиком внутри, либо не пересекает границу».
Контроль: **без фикса тест падает**, с фиксом — OK.

**Прогоны:** domain ALL PASS (16), e2e `E2E OK` (эталон 704.88),
domain-worker 22/22 ALL PASS. Визуально (pypdfium2, PNG): узкий габарит —
подпись под боксом, граница чистая; 50×30 — подпись внутри.

**Деплой:** коммит `62f6551` (push), `pp-domain-worker` пересобран на
сервере и выкачен (rollout Successful). Живая проверка на
`prepressplan.ru`: `POST /api/projects/{id}/reports/pdf` (с
`font_base64`) → 200, скачан PDF 801 297 байт, эскиз (стр. 2) — подпись
внутри бокса, граница чистая.

## 15. Подключение ключей ЮKassa (2026-09-28)

Владелец передал секретный ключ (`live_…`) и `shop_id=1453145`.

- Ключи записаны **только в k8s-секрет** `pp-secrets`
  (`YUKASSA_SHOP_ID`, `YUKASSA_SECRET_KEY`, `YUKASSA_WEBHOOK_SECRET` —
  последний сгенерирован на сервере, openssl rand -hex 24). В git
  ключей нет: `01-config.yaml` очищен от `test_shop/test_secret`,
  `21-billing.yaml` переведён на `secretKeyRef` (dry-run чистый).
- Rollout billing: healthz → `configured: true, provider: yookassa,
  webhook_signature: true, save_payment_method: false`.
- **`GET https://api.yookassa.ru/v3/me` (Basic shop:secret) → 200** —
  ключи валидны; `GET /payments/plans` → month 5000 / year 50000.
- **Живой checkout**: `POST /payments/checkout {plan:month}` → 200,
  заказ `72396983a3c04f9d887c0cc81c03ff51`, `confirmation_url`
  `https://yoomoney.ru/checkout/payments/v2/contract?orderId=324d8dd4-000f-5001-9000-11cb1d270e41`
  (создание платежа денег не списывает — они идут при оплате).
- **Осталось внешнее:** регистрация вебхука в кабинете ЮKassa
  (URL `https://prepressplan.ru/payments/webhook`, секрет — значение
  `YUKASSA_WEBHOOK_SECRET` из `pp-secrets`) и тестовая оплата.
  Статус заказа обновляется **только вебхуком** (опроса провайдера в
  коде нет) — без регистрации вебхука оплата не подтвердится.

## 16. Вебхук ЮKassa: сверка у провайдера вместо HMAC (2026-09-28)

**Сообщение владельца:** «не вижу вкладку вебхук» → раздел кабинета —
**Интеграция → HTTP-уведомления** (URL + события; секрета в кабинете нет).
Форма заполнена владельцем.

**Выявленный блокер:** официальная документация ЮKassa («Входящие
уведомления») не предусматривает HMAC-подпись тела — рекомендации:
проверка статуса объекта или IP. Наш `billing` требовал HMAC (fail
closed) → **реальные вебхуки были бы отклонены навсегда** (401 → ретраи
24 ч), оплата не подтвердилась бы.

**Фикс (`services/payments`):**
- `YooKassaProvider.process_webhook`: после парсинга тела —
  **`GET /payments|/refunds/{id}` нашими ключами**; статус объекта должен
  подтверждать событие (`_EXPECTED_STATUS`, иначе 422); все данные события
  берутся из ответа API, а не из тела (анти-фрод). Заголовок подписи —
  по-прежнему сверяется, **если прислан** (шлюзы; пустой секрет → 503).
- `UnconfiguredProvider`: без ключей API — всегда 503 (сверить нечего).
- `YooKassaProvider._request`: GET — без тела.
- `healthz` billing: добавлен `webhook_auth: "provider_recheck"`.

**Тесты:** payments **57 passed** (+6: unsigned→200 через сверку, неизвестный
платёж→502, неизвестный заказ→404, +5 юнитов продакшн-провайдера на
монкпатче `_request`: GET-путь, mismatch→WebhookPayloadError, 404 провайдера,
неверная подпись, refund-путь; стаб HTTP получил `do_GET`). Полный
pytest — **167 passed, 1 skipped**.

**Осталось:** деплой `pp-billing` + живая проверка (без подписи, статус
pending → ожидаем 422 «не подтверждает событие» — доказательство сверки) и
тестовая оплата владельцем.

**Деплой и живая проверка (2026-09-28):** коммит `69ab960` (push),
`pp-billing` пересобран/выкачен, healthz → `webhook_auth:
provider_recheck`. Три сценария на `prepressplan.ru/payments/webhook`
(без подписи, тело утверждало `payment.succeeded`):
- реальный платёж заказа `72396983…` → **422** «Статус объекта
  324d8dd4-… (**canceled**) не подтверждает событие» — сверка ходит в
  живой API ЮKassa (платёж тем временем истёк/отменён — старую ссылку
  оплаты не использовать);
- неизвестный id → **502** с реальной ошибкой 404 от api.yookassa.ru;
- прислана неверная подпись → **401**.
Фальшивку принять нельзя; положительный сценарий — после реальной оплаты
владельцем.

## 17. Paywall: «not found» при нажатии → checkout + confirmation_url (2026-09-28)

**Сообщение владельца:** «при нажатии происходит not found» (кнопка
«Оформить Pro»).

**Причина:** Flutter `purchase()` вызывал
`POST /payments/orders/{id}/confirm` — эндпоинт **удалён** ещё при
переходе на живую ЮKassa («тестовая оплата удалена», README) → 404 от
billing.

**Фикс (клиент, `app`):**
- `AccountGatewayHttp.purchase`: только `POST /payments/checkout` →
  возвращает заказ (метод `PaymentsApi.confirm` удалён как мёртвый).
- `LicenseController`: поле `openUrl` (тестируемая подмена,
  дефолт `openUrlExternal`); после checkout открывает
  `confirmation_url` в новой вкладке и делает `_refreshFromServer(quiet)`
  — локальный триал не трогается, пока вебхук не подтвердил оплату.
- `ensureSession` (вкладки/фокус): после успешной проверки `me` ещё
  подтягивает подписку — после оплаты Pro появляется без перезагрузки.
- Paywall: `err == null`, но Pro ещё нет → snackbar «Оплата открыта в
  новой вкладке…», окно НЕ закрывается (кнопка «Восстановить покупки» —
  ручной путь).

**Прогоны:** flutter analyze 0, `flutter test` **57/57** (+1: checkout →
открытие URL → Pro=false до вебхука, restore → Pro=true), `build web` OK.

**Деплой:** pp-web (см. ниже после выката).

## 18. Реальный SMS-провайдер sms.ru для подтверждения телефона (2026-09-28)

**Запрос владельца:** «настрой подтверждение по номеру телефона»
(сейчас — dev-режим, SMS не отправляется).

- Адаптер `_send_sms` (`services/auth`): `PP_SMS_PROVIDER=sms_ru` →
  `POST https://sms.ru/sms/send` (`api_id`, `to`, `msg` UTF-8, `json=1`;
  по официальной документации sms.ru/api/send); разбор
  `status/sms[номер].status`, ошибки → исключение → `sms_sent:false`.
  `PP_SMS_TEST=1` → `test=1` провайдера (без отправки и без списания).
- **Ужесточение:** `dev_phone_code` выдаётся только при
  `PP_SMS_PROVIDER=dev` — у реального провайдера код не попадает в ответ
  даже при сбое доставки (восстановление — только `confirm/resend`).
- Env: `PP_SMS_API_ID`, `PP_SMS_TEST` (`.env.example`, README auth,
  DEPLOY_CHECKLIST п.5).
- **Прогоны:** pytest **170 passed, 1 skipped** (+3: сокрытие dev-кода
  при сбое, флаг `sms_sent` при успехе, форма запроса sms.ru и
  ERROR-ответ).

**Осталось внешнее:** api_id аккаунта sms.ru → ключ в `pp-secrets`,
`PP_SMS_PROVIDER=sms_ru`, rollout auth, живая отправка (нужен баланс).

## 19. Регистрационные данные: имя и подтверждение пароля (2026-09-28)

**Запрос владельца:** форма регистрации — имя пользователя, почта,
телефон, пароль, подтверждение пароля.

- **Бэкенд** (`services/auth`): `RegisterIn.name` (обязательное, 1–100;
  пустое/пробельное → 422), колонка `users.name` (идемпотентная
  миграция), `_user_row` отдаёт `name` (login/register/confirm/me).
  Подтверждение пароля — клиентская валидация (сервер получает один
  пароль).
- **Клиент** (`app`): форма в режиме регистрации — поля «Имя
  пользователя» и «Повторите пароль»; валидация до отправки (пустое имя,
  «Пароли не совпадают»); `name` прокидут через
  `AccountGateway/AuthApi/LicenseController` (сигнатура
  `register(name, email, password, phone, deviceId)`).
- **Прогоны:** pytest **171 passed, 1 skipped** (+1: имя хранится и
  отдаётся в confirm/me); flutter analyze 0, `flutter test`
  **58/58** (+1 виджет-тест формы: пустое имя → подсказка, несовпадение
  паролей → подсказка, корректный ввод → уход в controller),
  `build web` OK.

**Деплой и смоук (2026-09-28):** `api_id` владельца — в `pp-secrets`
(`PP_SMS_API_ID`, в git не попадает); `01-config.yaml` →
`PP_SMS_PROVIDER=sms_ru`, `PP_SMS_TEST=1`; `20-auth.yaml` → env
`PP_SMS_PROVIDER`/`PP_SMS_TEST` (ConfigMap) + `PP_SMS_API_ID` (секрет).
Образы `pp-auth`/`pp-web` пересобраны и выкачены (rollout Successful);
healthz auth → `sms: sms_ru`. Смоук-регистрация (test=1, фейковый номер):
`202`, `dev_phone_code` не выдан ✓, но **`sms_sent: false`** — прямой
вызов `_send_sms` из пода показал ошибку **221 SMS.ru** («создайте
буквенного отправителя» → sms.ru/?panel=senders). Добавлен env
`PP_SMS_FROM` (параметр `from`); смок-пользователь удалён. Ожидание:
владелец создаёт отправителя → повторный смоук → `PP_SMS_TEST=0` →
реальная отправка. Тесты после правки: 34 passed.

## 20. UI-правки: юр. вкладка → копирайт; защита окна биллинга (2026-09-28)

- **Владелец:** убрать вкладку «Юридическая» и ссылку «Юридическая
  информация» из футера, открытие юр. страниц перенести на копирайт.
  Выполнено: `home_shell.dart` (5 пунктов навигации, футер — клик по
  «© 2026 Препресс-Планер» → `prepressplan.ru/legal`), экран
  `legal_screen.dart` удалён (использовался только вкладкой).
- **Владелец:** без авторизации нельзя открывать окно биллинга.
  `openPaywall`: если не залогинен — сначала экран входа; paywall
  открывается только после успешного входа (раньше окно открывалось
  сразу, вход подсовывался при нажатии покупки). Серверный
  `POST /payments/checkout` и так требует Bearer — это UI-гейт.
- **Проверка окна оплаты (запрос ранее):** по DOM живой страницы
  ЮKassa — 5 000 ₽, «Препресс-Планер: Pro на месяц», SberPay/ЮMoney/
  карта, таймер, «Выйти из оплаты» → `/billing/return`. Скриншот IAB
  стабильно отдаёт чужую вкладку (известная нестабильность).
- **Прогоны:** analyze 0, `flutter test` **59/59** (+2: без входа →
  экран «Аккаунт», не paywall; после входа → paywall), `build web` OK.

## 21. Админ-панель: отдельный сервис (2026-09-29)

**Запрос владельца:** админка — отдельный сервис; доступ по роли
admin/owner; полный набор (мониторинг бэкенда, аккаунты, доступы, БД,
подписки).

- **Новый сервис `services/admin`** (FastAPI, :8130, HTML-панель без
  сборки): гейт — вход через auth + роль owner/admin в **системной
  (первой по created_at) организации** (новые пользователи — owner только
  своей организации — в панель не попадают). auth.db монтируется тем же
  PVC (read-запросы + короткие write-транзакции revoke/delete);
  PostgreSQL — по `DB_URL`.
- Эндпоинты: `login`, `overview` (healthz web/api/auth/billing/converter/
  domain-worker/minio + счётчики), `users` (поиск/сессии/revoke/delete с
  каскадом; owner системной организации удалить нельзя), `access` (прокси
  auth API: роли member/viewer/admin), `subscriptions` (grant/revoke Pro
  прямой правкой проекции; возвраты — кабинет ЮKassa), `orders`, `db/tables`
  + `db/{table}` (whitelist, read-only, limit≤200), `healthz`, HTML `/admin/`.
- **auth**: `MemberAddIn.role` расширен до `member|viewer|admin` (admin
  назначает панель; owner через API по-прежнему нельзя), тест +3.
- **Инфраструктура**: `location /admin` в трёх nginx-конфигах
  (k8s/compose/tls), compose-сервис `admin`, k8s `25-admin.yaml`
  (Deployment+Service, init-контейнеры wait-auth/postgres, PVC auth-data),
  CI-строка `pytest services/admin/tests`.
- **Прогоны:** `pytest services/admin/tests` — **9/9**; auth — 34; полный
  контур — см. §21.1 (прогон после деплоя).

### 21.1 Деплой и живая проверка (2026-09-29)

Коммит `201a212` (push). На сервере собраны и импортированы `pp-admin`,
`pp-auth` (роль admin), `pp-web` (location /admin); применён
`25-admin.yaml`; rollout admin+auth+web — Successful, поды Running.

Живой прогон `https://prepressplan.ru`:
- `GET /admin/` → **200**, HTML панели (20 946 байт);
- `GET /admin/api/overview` без токена → **401**;
- `POST /admin/api/login` от `k8s-accept…` (member) → **403** «Требуется
  роль owner или admin в системной организации»;
- `POST /admin/api/login` от `info@…` (не член системной org) → **403**;
- неверный пароль владельца → **401** от auth;
- healthz admin: `db: configured`, `auth_db: /srv/auth/data/auth.db`.

Вход владельца: `vladimirkarateev@mail.ru` добавлен в системную
организацию ролью **owner** (k8s-accept понижен до member) — позитивный
вход выполняется его паролем (в тестах гейт покрыт: владелец → 200).

## 22. Мониторинг healthz с email-алертами (2026-09-30)

Пункт HANDOFF §17 п.7 закрыт (часть «мониторинг»): `deploy/k8s/monitor.py`
— опрос всех healthz (edge снаружи; остальные по ClusterIP, т.к. крон на
хосте без кластерного DNS; postgres — `pg_isready`). Креды SMTP берутся из
ConfigMap `pp-config` (в коде/git их нет), письмо — только при переходах
набора down ↔ up. Установлен cron `*/5 * * * *`, лог
`/var/log/pp-monitor.log`.

**Живые прогоны:** `--dry-run` → все 9 проверок OK (exit 0); реальный
прогон с подделанным state → письмо «Все сервисы восстановлены» отправлено
через SMTP хостинга (проверено фактом отправки), state нормализован
`down: []`.

## 23. UI участников организации (F-19, 2026-09-30)

Пункт HANDOFF §17 п.7 «UI участников» закрыт: API был — экрана нет.

- **Клиент:** `AccountGateway`/`AuthApi` — `myOrgs`, `listMembers`,
  `addMember` (added/invited), `removeMember` (DELETE `/auth/orgs/{id}/members/{uid}`).
- **Контроллер:** обёртки `organizationList`/`membersList`/`memberAdd`/
  `memberRemove` (error-строки в стиле сервиса; 401-сброс не нужен — auth
  сам).
- **Экран** `organization_screen.dart`: выбор организации (если несколько;
  по умолчанию — первая с ролью owner/admin), карточка org + ваша роль,
  список участников (email/имя/роль), удаление с подтверждением, форма
  «Добавить участника» (email + роль member/viewer/admin; для нового
  address — уходит приглашение по SMTP). Форма и удаление видны только
  owner/admin (`_canManage`); вход из профиля аккаунта — кнопка
  «Организация и участники».
- **Прогоны:** flutter analyze 0, `flutter test` **61/61** (+2: контроллер
  списка/добавления/удаления и error-ветки; виджет-тест экрана со списком
  из двух участников и формой управления), `build web` OK.

## 24. SMS-подтверждение удалено, восстановление пароля (2026-09-30)

Решение владельца: регистрация подтверждается **только по почте**, SMS
полностью убирается; кнопка «Забыли пароль?» уже была в коде — оставлена
и закрыта виджет-тестом.

**Что изменено:**
- `services/auth`: из `register` убран `phone` и отправка SMS, `confirm`
  сверяет только `email_code`, `confirm/resend` без `channel`; удалены
  `_send_sms`, `_check_phone`, env `PP_SMS_*`, поле `sms` в `/healthz`
  (заменено на `verify: "email"`); 403-текст входа — «Введите код с почты».
  Колонки `users.phone`/`phone_verified_at` и миграция не тронуты —
  исторические данные и админ-панель продолжают работать.
- `app` (клиент): в `AccountGateway`/`AuthApi`/`LicenseController` убраны
  `phone`/`phone_code`/`channel`; экран аккаунта — без поля телефона и
  SMS-кода, только «Код на почту повторно».
- Деплой: `PP_SMS_*` вычищены из `.env.example`, `docker-compose.yml`,
  `k8s/01-config.yaml`, `k8s/20-auth.yaml`; DEPLOY_CHECKLIST — снят пункт
  про SMS-провайдер, п.5 чек-листа (auth) обновлён под новый контракт.

**Восстановление пароля:** `/auth/forgot` → `/auth/reset` (код из письма,
TTL 30 мин, отзыв всех сессий) — без изменений; кнопка «Забыли пароль?»
на экране входа, шаг «Сброс пароля» (код + новый пароль).

**Прогоны (2026-09-30):**
- `.venv/bin/python -m pytest services/{converter,auth,payments,api,license}/tests -q`
  → **168 passed, 1 skipped** (auth: 31 — три теста SMS-провайдера удалены,
  добавлены проверки «телефон не требуется» и `verify: "email"`).
- `cd app && flutter analyze` → No issues found;
  `flutter test` → **62/62** (+1: «восстановление пароля: «Забыли пароль?»
  → код → новый пароль»: шаг сброса открывается, код и пароль из фейка
  меняют пароль).

### 24.1 Деплой на прод (2026-09-30)

Коммит `8626512` (push). На сервере `185.227.144.229`
(`/opt/pp/stack`, вход `ssh vps-cleanfine`):

- Синхронизированы `services/auth/`, `deploy/web/` (свежий
  `flutter build web`) и манифесты `01-config.yaml`/`20-auth.yaml`.
- Собраны и импортированы образы `pp-auth` и `pp-web`
  (`docker build` → `docker save | k3s ctr images import`).
- `kubectl apply` 01-config + 20-auth (ConfigMap и Deployment без
  `PP_SMS_*`), `rollout restart deploy/auth deploy/web` — оба
  **Successful**, 9/9 подов Running.

Живая проверка `https://prepressplan.ru` (фактические ответы):
- `auth /healthz` → `verify:"email"`, поля `sms` больше **нет**;
  `smtp:true`, `reset_ttl_min:30` (SMTP жив — коды уходят письмом).
- `POST /auth/register` **без телефона** (email уже существует) →
  **409** «Email уже зарегистрирован» — раньше без `phone` было бы 422;
  `POST /auth/confirm` **без `phone_code`** → **409** «Аккаунт уже
  подтверждён» (не 422); `POST /auth/confirm/resend` **без `channel`**
  → **200** `{ok:true}`.
- ConfigMap `pp-config`: ключей `PP_SMS_*` нет; у Deployment `auth`
  переменных `PP_SMS_*` нет (проверено `kubectl get deploy -o json`).
- Веб-бандл: md5 `main.dart.js` на проде совпадает со свежей локальной
  сборкой (`86588554728f705bb5638eb0cbd82c4f`) — в проде новый UI
  (кнопка «Забыли пароль?», форма без телефона, экран организации).
- `monitor.py --dry-run` → все 9 проверок OK; лог auth — только 200/409
  от смоук-запросов, ошибок нет.

### 24.2 Фикс вкладки «Аккаунты» в админке и его деплой (2026-09-30)

**Баг:** `https://prepressplan.ru/admin/` → вкладка «Аккаунты» падала с
`(u.created_at || "").slice is not a function` — у пользователей auth
`created_at` приходит **epoch (REAL, секунды)**, а строка звала `.slice`
у числа (участники не падали благодаря `String(...)`, но показывали
первые 10 цифр эпохи).

**Фикс** (`services/admin/admin_app/index.html`): хелпер `fmtDate(v)` —
число трактуется как epoch-секунды, строка как ISO; результат —
`YYYY-MM-DD` в локальной дате, `null`/пусто → пустая ячейка, нечисловая
строка → обрезка без исключения. Применён в таблицах аккаунтов и
участников; заказы (ISO `TEXT`) не тронуты.

**Прогоны:** `pytest services/admin/tests` → **9 passed**; проверка
`fmtDate` на epoch float/int, ISO, `null`, мусоре — без падений.

**Деплой (коммит `8c187a8`):** `services/admin` синхронизирован на
сервер → `docker build -t pp-admin` → `k3s ctr images import` →
`rollout restart deploy/admin` — **Successful**, под Running.

**Живая проверка:** `GET /admin/` → 200, в отданном `index.html`
`fmtDate` (3 вхождения), ячейки используют `fmtDate(u.created_at)` и
`fmtDate(m.created_at)`, старой строки `(u.created_at || '').slice` нет.
