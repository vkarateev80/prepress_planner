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
