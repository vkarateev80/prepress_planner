# HANDOFF — переезд «Препресс-Планер» на другой компьютер / в новую сессию

> **Для кого:** новая сессия агента (или разработчик) на другом компьютере.
> Этот файл — полный слепок контекста проекта: что сделано, где лежит,
> как проверить, что переносить, какие грабли окружения были на старой машине.
> Прочитайте его целиком перед любой работой.

- **Дата подготовки:** переезд (снимок состояния на коммит `35a5711`, ветка `master`, 25 коммитов, дерево чистое).
- **Актуальность:** обновлено 2026-09-26 — снимок на коммит `285347b`, ветка **`main`**,
  46 коммитов, дерево чистое; выполнены SaaS-контур (api/domain-worker/reports),
  `flutter-web-adapt` целиком, эксплуатация (TLS/nginx/PG/бэкапы) — см. §12 и `docs/VERIFICATION.md` §8.
- **Проект:** «Препресс-Планер» — мультиплатформенное (iOS · Windows · macOS · Linux) приложение
  препресс-планирования расходных материалов и экономико-технического обоснования (ТЭО) тиражей этикеток.
- **Парадигма (утверждена заказчиком):** планирование расходных материалов препресса + ТЭО.
  УФ-маска и генерация УП/G-кода **намеренно удалены** из новой версии (остались только в легаси-эталоне).
- **Монетизация (утверждена):** Free → Pro по подписке, триал 15 дней; статьи затрат —
  материал ₽/м², сортамент, машиночасы, скорость печати, переналадка, рабочее время.

---

## 1. Карта репозитория

```
<корень>/                      = git-репозиторий (ветка master)
├── packages/core/             ЧИСТЫЙ Dart-домен (без Flutter, без pub.dev): ВСЯ математика
│   ├── lib/prepress_core.dart — баррел; под-папки: model, geom, parser, healer,
│   │                           optimizer, calculator, manufacturability, economics, reports
│   ├── test/*_test.dart       16 исполняемых тест-скриптов (void main(); не пакет test)
│   ├── tool/test_utils.dart   хелперы (expect/expectEq/expectNear/ok)
│   └── tool/e2e.dart          сквозной сценарий (эталонные числа)
├── app/                       Flutter-приложение (UI «Препресс-Планер»)
│   ├── lib/main.dart          вход; LicenseController со старта (триал 15 дн.)
│   ├── lib/src/               projects (store v2), screens (5 вкладок), widgets
│   └── lib/license/           license_client, entitlement_store (+FeatureGate/TrialTimer),
│                              license_controller (ChangeNotifier), paywall_screen
├── services/converter/        FastAPI: AI/CDR/EPS → SVG/PDF (пакет converter_app)
├── services/license/          FastAPI: триал/ключи/подписки/webhooks (пакет license_app)
├── scripts/run_domain_tests.{ps1,sh}  цикл по тестам домена
├── .github/workflows/{ci,release}.yml  CI (скачивает SDK на раннере — путей нет)
├── fixtures/                  эталонные файлы для тестов (в git, 11 МБ)
├── agents/00..14.md           контракты субагентов (история исполнения)
├── docs/VERIFICATION.md       приёмка §10 спеки фактическими выводами
└── docs/superpowers/{specs,plans}/  спека + план реализации
```

Легаси-эталон (НЕ в git, `.gitignore`): `cam_pipeline/`, `cam_material/` — исходный Python-код,
из которого портирован домен. Нужны только как оракул для сверки (shapely/ezdxf/PyMuPDF).

## 2. Статус проекта — ВСЁ ВЫПОЛНЕНО

| Фаза | Содержание | Статус |
|---|---|---|
| Ф0 | git, монорепо, спека, план, контракты 00–14, фикстуры | ✅ `2629ee9` |
| Ф1 | домен: геометрия, парсеры DXF/SVG/PDF/AI, лечение, массивы, расход+shape, технологичность | ✅ `60be4ab`…`bd3a211` |
| Ф2 | экономика/ТЭО + отчёты PDF/XLSX/DXF | ✅ `f6986fb`, `57d7bc6` |
| Ф3 | Flutter UI (MVP, 5 вкладок) | ✅ `7196c01` |
| Ф4 | конвертер + лицензии + подписка (триал 15 дн.) | ✅ `7840767`, `426cc41`, `68c566c` |
| Ф5 | CI, E2E, верификация | ✅ `bb1a7c3`, `6b274c0` |
| SaaS | `services/api`, `domain-worker`, отчёты §12.8, облачные проекты/файлы (`flutter-web-adapt`), эксплуатация (dev-TLS, `nginx -t`, PostgreSQL-тесты, `backup.sh`, миграция образов MinIO) | ✅ коммиты `742b08b`…`285347b` (2026-09-26) |

**Цель (goal) закрыта.** Все критерии приёмки §10 спеки подтверждены живыми прогонами —
см. `docs/VERIFICATION.md` (заполнено фактическими выводами, не обещаниями;
§8 — сводка прогонов от 2026-09-26: pytest 143, flutter 50/50, E2E 1:1,
`nginx -t`, `docker compose config`, бэкапы).

### Эталонные числа (самопроверка после переезда)

- Расход 50×30/зазоры 3/Z96/CP3.175/N5000: **9×5, N=5040, оборотов=112, длина=34137.6 мм,
  отходы=26.18%, на этикетку=2032.0 мм²/шт** (раппорт 304.8 мм).
- ТЭО эталон: costPer1000=**704.88 ₽**, totalCost=3552.58, machineCost=2528.45, materialCost=1024.13,
  runTime≈0.0057 ч, загрузка смены 6.32%.
- E2E печатает всё это и завершается `E2E OK`, код выхода 0.

## 3. Как проверить на новом месте (команды)

```bash
# 1. Домен (из корня)
bash scripts/run_domain_tests.sh                  # → ALL PASS (16 файлов)
(cd packages/core && dart tool/e2e.dart)           # → E2E OK

# 2. domain-worker (из корня; analyze + тесты + эталон + отчёты)
bash scripts/run_domain_worker_tests.sh           # → ALL PASS (domain-worker)

# 3. Flutter (из app)
cd app && flutter analyze && flutter test && flutter build web --release
#   → No issues found! / 50/50 / Built build/web

# 4. Сервисы (из корня): нужен Python ≥3.11 (код использует X | None;
#    системный 3.9 НЕ подходит — сделайте python3.11 -m venv .venv и pip install
#    fastapi uvicorn python-multipart pytest httpx sqlalchemy cryptography "pydantic[email]" psycopg2-binary)
.venv/bin/python -m pytest services/converter/tests services/auth/tests \
  services/payments/tests services/api/tests services/license/tests -q   # → 143 passed, 1 skipped

# 5. То же на реальном PostgreSQL 16 (docker): PP_TEST_DB_URL=postgresql://… pytest …
#    (общие таблицы чистит services/api/tests/conftest.py)

# 6. Греп-контроль (в core нет маски/G-кода)
grep -riE 'uv_mask|gcode|g_code|уф|уп' packages/core/lib   # → 0 (кроме «управляющие символы» в XML-комментарии)
```

CI (`.github/workflows/ci.yml`) — **5 джоб**: domain, domain-worker, flutter, services (pytest),
deploy (`docker compose config` + `nginx -t` обоих конфигов).

## 4. Что переносить (варианты)

**В git только исходники + фикстуры (~25 МБ).** Машинно-зависимое — НЕ в git:

| Что | Где | Размер | Зачем |
|---|---|---|---|
| Dart SDK 3.13.3 | `.tools/dart-sdk` | часть .tools | домен |
| Flutter 3.47.2 stable | `.tools/flutter-src/flutter` | `.tools` всего ~5.9 ГБ | app |
| pub-cache | `.tools/pub-cache` | там же | flutter (path-зависимость на core) |
| Python venv 3.12.4 | `cam_pipeline/venv` | `cam_pipeline` всего ~2 ГБ | сервисы + оракул |
| Движки | `cam_pipeline/inkscape_engine` (работает), `cam_pipeline/ghostscript_engine` (в песочнице не стартует) | там же | конвертер |

**Вариант A (быстрый, рекомендуется):** скопировать ВСЮ папку целиком (~8 ГБ, можно без
`app/build`, `app/.dart_tool`, `services/converter/data`, `*.db` — они пересоздаются).
Всё работает сразу: пути в коде/скриптах совпадают (см. §6 про захардкоженные пути).

**Вариант B (чистый):** `git clone`/копия только исходников, затем восстановить инструменты:
1. Dart SDK 3.13.3 → в `.tools/dart-sdk` (или в PATH);
2. Flutter stable (версия в `app/pubspec.lock`/`flutter --version`; движок — см. §6),
   `flutter pub get` в `app/`;
3. Python 3.12 + `pip install -r services/converter/requirements.txt
   -r services/license/requirements.txt` + (для оракула) shapely ezdxf pymupdf;
4. Inkscape + Ghostscript в любое место, указать через env (см. §6) или положить по путям ниже.

## 5. Технические факты (для быстрого входа в код)

- **Домен:** только stdlib Dart. Тест-файл = скрипт: запуск `dart test/<file>.dart` из
  `packages/core`, код выхода 0 = успех. Баррел `prepress_core.dart` экспортирует всё.
- **UI:** `HomeShell` (6 вкладок: + «Юридическая»; десктоп — NavigationRail, узкий — NavigationBar).
  `ProjectStore('projects')` — два режима: локальный JSON v2 (desktop/localStorage) и
  **облачный** (web + активная сессия → `services/api`, CRUD `/api/projects`, env `PP_API_URL`,
  web-фолбэк `/api`). **Ловушка `env_web`:** `envOrDefault` на web возвращает именно
  `fallback` (так чинился баг `285347b` — раньше всегда `''` и обнулял `/api`);
  web-фолбэк для сервисов одного origin — пустая строка.
  `LicenseController` в `main.dart`:
  первый запуск → MachineId + офлайн-триал 15 дней → кэш `state/entitlement.json`;
  `sessionToken` — Bearer для облачных вызовов.
  Гейтинг: `FeatureGate.hasProAccess` (Pro **или активный триал**); Free = 1 проект +
  прямоугольный расчёт; вкладки Геометрия/ТЭО/Отчёты и «Перебор вариантов» — Pro
  (шторка «Доступно в Pro» → paywall). Web-сборка: `flutter build web --release` → `app/build/web`.
- **Сервисы:** FastAPI, пакеты `converter_app`/`license_app` (имена НЕ `app` — коллизия).
  Лицензии: SQLite (наивный UTC `datetime.utcnow()`), HMAC offline-токены,
  грэйс 30 дней, триал 15 дней однократно. Конвертер: файловый stdio для движков,
  джобы в памяти, результат в `data/out/<uuid>/`.

## 6. Захардкоженные пути и env-переменные (важно для Варианта B)

| Файл | Что | Как обойти |
|---|---|---|
| `services/converter/converter_app/convert.py` | `INKSCAPE`, `GHOSTSCRIPT` | env `PP_INKSCAPE`, `PP_GHOSTSCRIPT`; без env — авто-поиск: Inkscape из `cam_pipeline\inkscape_engine`, Ghostscript из `cam_pipeline\ghostscript_engine` и `C:\Program Files[ (x86)]\gs` (2026-09-03) |
| `scripts/run_domain_tests.ps1` | `.tools/dart-sdk/bin/dart.exe` | fallback на `dart` из PATH |
| `packages/core/README.md`, `app/README.md` | упоминания абсолютного пути | только документация |

Движок Flutter (для Варианта B без интернета к google): переменные
`FLUTTER_STORAGE_BASE_URL=http://storage.googleapis.com`,
`FLUTTER_PREBUILT_ENGINE_VERSION=a804b261645ef8c13eb3d5c44a5c2fb0340c5539`
(значение брать из `.tools/flutter-src/flutter/bin/cache/` старой машины).
Git на Windows: при «dubious ownership» добавлять `-c safe.directory='*'`.

## 7. Грабли окружения СТАРОЙ машины (не переносятся, но объясняют код)

- HTTPS к большинству хостов блокирован; рабочий канал — `http://storage.googleapis.com`.
- pub.dev недоступен → правило «только stdlib Dart» — **осознанное**, не лень.
- PowerShell-песочница DSH: нельзя пайпить вывод нативных команд и `2>&1`;
  git — только с `safe.directory`; движки конвертера запускаются с файловым stdio
  (пайпы EPERM).
- Ghostscript: на старой машине «не стартует (0xC0000142)» — на текущей рабочий
  `gswin32c` 8.64 (`C:\Program Files (x86)\gs\gs8.64`) и движок 10.07.1 в
  `cam_pipeline\ghostscript_engine`; конвертер ищет их автоматически (2026-09-03).
- Файлы только UTF-8; PowerShell `Set-Content` портит кириллицу — писать через редактор/write.
- **Образы MinIO удалены с Docker Hub** (архивация community-издания, Oct 2025 – фев 2026):
  `minio/minio`/`minio/mc` → 404. Стек переведён на `alpine/minio:RELEASE.*` (пин,
  `user: root` — тома root-овые, healthcheck на `wget`) + `amazon/aws-cli` вместо mc
  (см. `deploy/README.md`). `quay.io/minio/*` из части сетей недоступен.
- **Python:** сервисы требуют ≥3.11 (`X | None` в типах); системный 3.9 падает на
  импорте. Рабочий вариант — `.venv` (python3.11), он в `.gitignore`.
- **Порты:** 5432 может быть занят SSH-туннелем — для тестового PostgreSQL
  публикуйте другой (например, 127.0.0.1:5433).

## 8. Конвенции проекта (соблюдать и дальше)

- Коммиты: по одному на модуль/фазу, сообщения на русском вида «Ф4-12b: …»; git — журнал прогресса.
- Не коммитить артефакты: `services/converter/data/`, `*.db`, `__pycache__`, `.dart_tool`, `build/` (в .gitignore).
- Числа: координаты мм с 4 знаками, деньги 2 знака; тексты ошибок/UI — русские.
- В `packages/core` не появляются модули УФ-маски и G-кода (греп-контроль в CI/VERIFICATION).

## 9. Что дальше (открытые направления — выбирать заказчику)

Закрыто в сеансе 2026-09-26: `flutter-web-adapt` (облачные проекты, серверная
конвертация ADR-7, отчёты §12.8, файлы §12.5), эксплуатация (dev-TLS-скрипт,
`nginx -t`, тесты на PostgreSQL 16, `deploy/backup.sh`, миграция образов MinIO,
CI — 5 джоб). Подробности — §12 и `docs/VERIFICATION.md` §8.

Статус пунктов (актуально на 2026-09-27; детали — `docs/VERIFICATION.md`
§9–§10, `deploy/DEPLOY_CHECKLIST.md`):

1. **Прод-TLS**: скрипт готов — `bash deploy/nginx/get_prod_certs.sh`
   (webroot-HTTP-01: ACME-location в `pp-web-tls.conf` до редиректа,
   certbot в docker, состояние `deploy/certbot/`; самопроверка DNS/порта 80).
   Остаётся внешнее: домен с DNS на сервер → запуск скрипта (чек-лист §2).
2. **Ключи ЮKassa** (shop_id/secret/webhook-secret + регистрация webhook-URL)
   и **SMTP** (`PP_SMTP_*`) — только внешние действия в кабинетах; код и
   шаблоны готовы (`.env.example`, DEPLOY_CHECKLIST «Внешние действия без
   кода», receipt/автоплатежи — п.6).
3. ~~**Offsite-копия**~~ — **СДЕЛАНО** (2026-09-27): шаг 3/3 в
   `deploy/backup.sh` по `PP_OFFSITE_*` (любой S3-совместимый провайдер),
   cron и примеры — `deploy/README.md`/`.env.example`. Пойман и исправлен
   баг: `docker compose run minio-init` исполнял compose-entrypoint
   (health-скрипт) вместо команды sync — **бэкап bucket молча не делался**;
   теперь `--entrypoint /bin/sh`, живой прогон 3/3 шагов с подтверждением
   `s3 ls`. Остаётся внешнее: bucket/ключи у провайдера + включить cron.
4. ~~**Живой UI-прогон web-сборки** (импорт файла → расчёт → PDF)~~ —
   **ЗАКРЫТ** 2026-09-26 (сессия продолжения): сценарий целиком через UI,
   эталон 1:1; найдены и исправлены два прод-бага — `AuthApi` не принимал
   `201 Created` от `/auth/register` (регистрация падала) и `files_web.dart`
   ждал `ByteBuffer` вместо приходящего на web `Uint8List` (веб-импорт молча
   не работал). Подробности и доказательства — `docs/VERIFICATION.md` §9;
   стек/скрипты прогона — `~/.pp_live/` (start.sh, stage*.js).
5. ~~**Приглашения участников** (F-19)~~ — **ГОТОВО** (2026-09-27):
   `GET/POST /auth/orgs/{id}/members`, `POST …/invites/accept`,
   `DELETE …/members/{user_id}`; таблица `invites` (TTL 7 дней, sha256),
   автоприём при регистрации, SMTP или dev-код, защита последнего owner;
   auth-тесты 26 passed (см. VERIFICATION §10.1).
6. ~~Чеки/автоплатежи ЮKassa (ADR-3)~~ — **ГОТОВО** (2026-09-27):
   `receipt` в checkout (`YUKASSA_RECEIPT_ENABLED`/`YUKASSA_RECEIPT_VAT_CODE`,
   email из сессии), `save_payment_method` покрыт тестом; платежей 51 passed.
   Ретеншен bucket и `nginx -t` в CI — уже были сделаны ранее.
7. iOS IAP (StoreKit) — **блокер**: нужны macOS/Xcode + аккаунт Apple
   Developer; что именно и что уже готово в коде — DEPLOY_CHECKLIST
   «Внешние действия без кода».

## 10. Ключевые документы

- Спека: `docs/superpowers/specs/2026-09-02-prepress-planner-design.md`
- План: `docs/superpowers/plans/2026-09-02-prepress-planner.md` (все задачи отмечены выполненными)
- Приёмка: `docs/VERIFICATION.md`
- Контракты агентов: `agents/00..14.md` (история; новые работы не обязаны им следовать)
- README корня: `README.md`

## 11. Последние изменения сеанса (2026-09-03)

- **Краши устранены**: Isolate-расчёты через топ-левел функции (setState-замыкание
  больше не захватывается изолятом — «object is unsendable»); все post-await
  `setState` под `if (mounted)` (переключение вкладок во время расчёта безопасно).
  Регрессионные тесты: `app/test/layout_isolate_test.dart`, `teo_speed_test.dart`.
- **UI**: подписи параметров раскроя над полями (не вылезают на соседей);
  всплывающие комментарии при наведении на параметры (Раскрой/ТЭО/Геометрия);
  «Обзор…» — встроенный диалог выбора векторного файла.
- **ТЭО**: слайдер «Скорость, м/мин» теперь реально влияет на себестоимость
  (скорость подставлялась в `_machineWithRate` только с 2026-09-03).
- **Импорт**: SVG/DXF-разбор и анализ — поэтапные статусы и таймаут 90 с (вместо
  «вечной загрузки» — понятная ошибка). EPS: конвертер авто-ищет Ghostscript.
- **Массив**: «Распознать массив» = мастер-элемент + закон (ряды×колонки, шаг,
  зазоры) → лечение только мастера (слой `MASTER`) → размножение на слой `ARRAY`
  → **автозаполнение параметров раскроя**. `Project.pattern` сериализуется
  полностью (masterPaths/offsets/gapX/gapY). Холст раскрашивает слои.
- **Журнал событий**: кнопка в шапке (любая вкладка) → окно «Журнал событий».
  In-memory лента `AppLog` (`app/lib/src/logs/app_log.dart`, ChangeNotifier,
  I/W/E, лимит 2000 записей, в диск не пишется); глобальный перехват
  `FlutterError.onError`/`PlatformDispatcher.onError` в `main()`; строки —
  SelectableText (выделение) + «Копировать всё» (Clipboard); бейдж с числом
  ошибок; окно `app/lib/src/widgets/log_window.dart`. Пишут этапы и ошибки
  экраны Геометрия, Отчёты и Раскрой (расчёт/перебор/«Применить»/ошибки
  расчёта, источник «Раскрой»). Тесты: 24/24 зелёные.
- **Производительность лечения (ваш PDF «…в кривых», 319 контуров / 37 408
  точек)**: «Вылечить всё» упиралось в таймаут 90 с из-за квадратичного
  нодинга (O(segments²), ~37 тыс. отрезков × три глобальных прохода:
  polygonize → сварка unaryUnion → «хвосты»). Добавлен пространственный
  индекс: `_bboxOverlapNeighbors` в `packages/core/lib/src/geom/geom_boolean.dart`
  (равномерная сетка по bbox, сегмент в каждой покрытой ячейке; пара
  добавляется симметрично в списки обоих сегментов) — применяется в
  `_nodeSegments` и `nodeLineSegments`; в `morphology.dart` «лежит ли хвост на
  грани» ищется через `_BoundaryGrid` (ячейка + 8 соседей). Численно
  результаты ПОБИТОВО те же (сетка лишь отсекает заведомо пустые пары).
  Замер на файле: лечение **>90 с (таймаут) → 16 с**; анализ 7–9.5 с.
  Полный путь «Вылечить всё» ≈ 26 с. Все core-тесты и flutter-тесты зелёные.
  Диагностический инструмент: `packages/core/tool/profile_heal.dart`
  (`dart run tool/profile_heal.dart "<файл>"`). В ошибках лечения/распознавания
  журнал теперь указывает имя файла.
- **Варианты раскроя — кнопка «Применить»**: выделение строки в таблице
  больше не применяется мгновенно. Сначала строка подсвечивается (кандидат),
  под таблицей показан её состав; расчётным вариант становится только по
  кнопке **«Применить»** (calc + selectedVariantIndex → ТЭО и отчёты).
  Сброс выбора — при пересчёте/переборе вариантов.
- **Поиск ошибок после извлечения массива**: когда массив распознан
  (`pattern.isArray`, мастер на слое `MASTER`), приложение работает ТОЛЬКО с
  мастер-элементом из слоя извлечённого массива: заголовок списка «Ошибки
  мастер-элемента (этикетка)»; «Вылечить всё» и «Исправить» в этом режиме
  лечат/исправляют мастер (не весь лист), ошибки считаются по мастеру,
  слой `ARRAY` пересобирается по тому же закону автоматически
  (`_healMasterAndRebuild`/`_commitMaster`/`_applyFix…` в geometry_screen.dart).
- **Поиск ошибок (анализ) на контурах-гигантах — больше не падает по
  таймауту**: ваш SVG «…в кривых» — 75 контуров, но 383 444 точки (топ
  98 719 точек в одном контуре). Квадратичные проверки упирались в 90 с.
  Сделано в `packages/core/lib/src/manufacturability/`:
  самопересечения и пары контуров ищутся по единой bbox-сетке
  `_overlapNeighbors` (результаты численно те же; ускорение
  >90 с → 0.7 с на файле); проверка «малых зазоров» на гигантских файлах
  (≥120 тыс. точек суммарно) автоматически пропускается — она была самой
  тяжёлой (90–280 с на этом файле) и при лимите maxPairs≈300 для гигантов
  почти всегда пуста. Итог импорта файла: разбор 0.14 с, анализ **0.8 с**,
  2144 проблемы найдены. Все core-тесты (14 файлов) и flutter-тесты зелёные.
  Диагностика: `packages/core/tool/stat_analyze.dart` (замер каждой проверки).
- **Единицы и приладка (ТЭО)**: материальные величины ТЭО/отчётов переведены
  в метры — «Длина полотна»/«Длина» в **м** (мм/1000), площади полотна/
  этикеток/отходов и «на этикетку» — в **м²** (мм²/1e6); технологические
  размеры (этикетка W×H, зазоры, раппорт, цилиндр/полотно) остались в мм.
  Затронуто: экран «Раскрой» (результат, строка «Применить»), таблица
  «Варианты», PDF-отчёт (04) и XLSX (05). Добавлен расход материала на
  **приладку** (переналадку), погонные метры: поле `Machine.setupMaterialMeters`
  (+JSON каталога), в ТЭО поле «Приладка: материал, м» (блок «Каталог затрат»);
  метры прибавляются к длине полотна тиража и увеличивают стоимость материала
  (машинное время не меняется). Тесты economics/reports/material + flutter 24/24.
- **Геометрия — ширина материала после распознавания**: блок «Ширина материала»
  (показывается в режиме массива): ширина макета = крайний левый ↔ правый
  элемент (`_patternSpanX` по offsets копий + labelW), редактируемые
  «Поле слева/справа, мм», «Сдвиг макета, мм» (вправо/влево от оси симметрии,
  ограничен полями) и живая «Рекомендуемая ширина материала =
  макет + поля»; кнопка «Применить к раскрою (полотно)» пишет ширину в
  `params.webWidth`. Файл `app/lib/src/screens/geometry_screen.dart`.
- **Раскрой — рейтинг по магнитным валам (Z)**: блок «Рейтинг по магнитным
  валам (Z)»: редактируемый список Z (по умолчанию 24, 28, 32, 36, 40, 48,
  56, 64), «Рассчитать рейтинг» считает расход для каждого Z (раппорт =
  Z × CP), ранжирование переключается чипами: по отходам % / по длине, м /
  по N этикеток (★ лучший); клик по строке применяет вал Z и его расчёт
  (`params.zTeeth` + calc). Файл `app/lib/src/screens/layout_screen.dart`.
- **ТЭО — смена и её цена**: в «Каталоге затрат» добавлены «Смена, ч», «Смен
  в сутки» (мощность = часы × смен; влияют на загрузку) и «Цена смены, ₽»
  (`TeoInput.shiftCostPerShift`). Занятых смен = ⌈(время + переналадка) / часов
  в смене⌉ → статья «Смена, ₽» (`TeoResult.shiftsUsed/shiftCost`) в итоге,
  наценке и себестоимости; добавлено на экран ТЭО и в PDF/XLSX отчёты.
- Открыто: реальные большие SVG/DXF (файлы пользователя) на «бесконечную загрузку»
  не воспроизведены — механизм таймаута/статусов добавлен; проверить на реальных
  файлах. Коммит изменений (Ф6-01 + UI + массив + журнал + оптимизация лечения
  + «Применить» + режим мастера) не оформлен — на согласовании.

---

## 12. Сеанс 2026-09-26: SaaS-контур закрыт, эксплуатация, живой прогон

**Коммиты (все в `main`, origin синхронен):**

| Коммит | Содержание |
|---|---|
| `d7d9402` | Отчёты по API (§12.8): стадия `/reports` в domain-worker, `POST /api/projects/{id}/reports/{fmt}`, экспорт из UI через api |
| `742b08b` | `flutter-web-adapt`: файлы в облако — `uploadSource` (§12.5), `GET /files/{id}/download`, `inputFileId` |
| `2819439` | Эксплуатация: `gen_dev_certs.sh`, `nginx -t`, pytest на PostgreSQL 16, `backup.sh`, замена удалённых образов MinIO |
| `82e2870` | Хвосты: `lastOriginalFileId` для закрытых форматов, CI-джоба `deploy`, удалён мёртвый `legal_nav.dart` |
| `285347b` | **env_web-фикс** (см. ниже) + `docs/VERIFICATION.md` §8 |

**Главный пойманный баг (env_web, `285347b`):** `env_web.envOrDefault` возвращал всегда
`''`, игнорируя фолбэк → на web `ProjectsApi` ходил мимо `/api` → SPA отдавал HTML →
`jsonDecode` падал (непойманные `Error` в консоли) → **облачное хранилище в прод-сборке
не работало бы**. Unit-тесты не ловили (передают `baseUrl` явно). Найден только живым
прогоном. Фикс: возврат `fallback` + `ApiException` на не-JSON ответ + тест-регрессия.

**Живой прогон (macOS):** локальный стек без compose (5 сервисов + edge-nginx, см. §3)
подтверждён в браузере: логин/сессия через перезагрузку, облачный список проектов,
`POST /api/projects 201` + `PATCH 200`, `GET /projects/{id} 200`. Не доведён до конца
импорт файла → расчёт → PDF: расширение браузера отдаёт `filechooser: ambiguous
routed session`, синтетические клики нестабильны (сбой на стороне инструмента, не кода).
Серверные пути этих операций покрыты pytest (143) и E2E (delta 0.0).

**Технические заметки сеанса:**
- `docker compose config` требует `PP_AUTH_SECRET` (секрет-плейсхолдер допустим в CI).
- `nginx -t` в контейнере: апстримы через `--add-host <имя>:127.0.0.1`; для
  `pp-web-tls.conf` нужен сертификат (генерируется скриптом).
- ILM MinIO: `AbortIncompleteMultipartUpload` эта сборка молча отбрасывает
  (проверено `put/get-bucket-lifecycle-configuration`) — ретеншен через api-версионирование.
- Браузерный флоу: `MaterialApp.title` не обновляет `document.title` — состояние
  проверять по скриншоту UI, а не по заголовку вкладки.

---

## 13. Сеанс-продолжение 2026-09-26: живой UI-прогон web (§9 п.4 закрыт)

**Сделано:**
- Локальный стек поднят заново без compose (`~/.pp_live/start.sh` /
  `stop.sh`; сервисы — полный detach через setsid, edge-nginx `pp-edge:8080`
  с прокси на `host.docker.internal`; `api` — `PP_STORAGE_BACKEND=memory`).
  Web пересобран после фикса env_web (прежняя сборка ему предшествовала).
- Сценарий «регистрация → логин/сессия → облачный проект → импорт
  `fixtures/petlya.svg` → раскрой → ТЭО → PDF/XLSX» прогнан через UI
  Playwright-API (channel `chrome`, нативный перехват `filechooser` —
  проблема прошлой сессии обойдена). Скрипты: `~/.pp_live/stage*.js`.

**Два прод-бага, пойманные только живым прогоном (исправлены):**
1. `AuthApi._post` (`app/lib/license/account_client.dart`) принимал только
   `200`, а `/auth/register` отдаёт **201** → регистрация показывала сырой
   JSON и не сохраняла сессию. Фикс: приём любых 2xx; регрессионный тест
   `app/test/license_account_test.dart` (падает без фикса).
2. `pickSingleFile` (`app/lib/platform/files_web.dart`) проверял
   `result is ByteBuffer`, а на web `FileReader.result` — **Uint8List** →
   выбор отбрасывался молча: **веб-импорт не работал вовсе**. Фикс: принимать
   оба типа.

**Проверки (зелёные):** `flutter analyze` 0 · `flutter test` **51/51** ·
`flutter build web` ОК · эталон в облачном state и в скачанном
`04_ТЭО_Отчёт.pdf` 1:1 (9×5, 5040, 112, 26.18 %, 304.8, 34137.6,
704.88 ₽/1000, 3552.58, 2528.45, 1024.13, 0.0057 ч, 6.32 %) ·
`05_Расчёт.xlsx` (3 листа) · непойманных ошибок консоли — 0.
Подробности — `docs/VERIFICATION.md` §9.

**Изменения в дереве (не закоммичены):** `account_client.dart`,
`files_web.dart`, `license_account_test.dart`, `docs/VERIFICATION.md` (§9),
этот файл (§9 п.4, §13). Стек работает (`~/.pp_live`) — остановить
`bash ~/.pp_live/stop.sh`, если больше не нужен.

**Остаётся из §9:** прод-TLS (certbot), ключи ЮKassa+webhook+SMTP,
offsite-бэкапы, приглашения F-19, чеки/автоплатежи ADR-3, iOS IAP.

---

## 14. Сеанс-продолжение 2026-09-27: закрытие §9 (п.1–3, 5–7)

**Сделано (подробности — `docs/VERIFICATION.md` §10):**

- **F-19 приглашения** (`services/auth`): 4 роута (список/добавление/
  accept/удаление), таблица `invites` (TTL 7 дней, sha256-код), автоприём
  приглашений при регистрации (в той же транзакции), SMTP-письмо или dev-код
  без SMTP, защита последнего owner, роли только `member`/`viewer`.
  Тесты: auth 26 passed (+7). README auth обновлён.
- **ADR-3 чеки** (`services/payments`): объект `receipt` в создании платежа
  (customer.email из principal, items/service/full_payment,
  `YUKASSA_RECEIPT_ENABLED`, `YUKASSA_RECEIPT_VAT_CODE`); сквозной тест
  «email из сессии → payload»; `save_payment_method` закрыт тестом.
  Тесты: payments 51 passed (+7). README + `.env.example`.
- **Offsite-бэкапы** (`deploy/backup.sh`): шаг 3/3 — вынос на внешний
  S3-совместимый бэкет по `PP_OFFSITE_*`; cron/примеры в README и
  `.env.example`. **Пойман баг**: `docker compose run minio-init`
  исполнял compose-entrypoint (health-скрипт) вместо команды sync — шаги
  бэкапа bucket молча ничего не делали; фикс — `--entrypoint /bin/sh`
  (в обеих шагах). Живой прогон: pg_dump + download + offsite upload,
  `s3 ls` подтверждён; убрана вложенность `bucket/bucket`.
- **Прод-TLS** (`deploy/nginx/get_prod_certs.sh` + ACME-location в
  `pp-web-tls.conf` + mount `deploy/acme/`): webroot-HTTP-01, certbot в
  docker (`deploy/certbot/`, в `.gitignore`), установка в `nginx/certs/` +
  reload, самопроверка DNS/порта до запроса. Проверено: `nginx -t`,
  живая отдача челленджа и 301, guard-путь на фейковом домене.
  Выпуск — требует домен (внешнее действие).
- **Внешние действия** сведены в `DEPLOY_CHECKLIST.md` («Внешние действия
  без кода»): домен/DNS, ключи ЮKassa+webhook, SMTP, offsite-бэкет, и
  **блокер iOS IAP** (Xcode + Apple Developer Program + App Store Connect;
  paywall/entitlement в коде уже готовы).

**Прогоны (зелёные):** pytest все сервисы — **157 passed, 1 skipped**
(было 143: +7 F-19, +7 receipt); `docker compose config`; `nginx -t`
для конфига с ACME; `bash -n` обоих скриптов. Flutter не менялся —
анализ/тесты предыдущего сеанса (0 / 51/51) актуальны.

**Изменения в дереве (не закоммичены):** services/auth (2 файла),
services/payments (7), deploy (backup.sh, get_prod_certs.sh, pp-web-tls.conf,
docker-compose.yml, README, DEPLOY_CHECKLIST, .env.example), .gitignore,
services/auth/README.md, docs/VERIFICATION.md (§10), docs/HANDOFF.md (§9, §14).

**Осталось (только внешнее):** домен → get_prod_certs.sh; ключи
ЮKassa/webhook; SMTP; offsite-бэкет + cron; Apple-аккаунт → iOS IAP.

---

## 15. Правовые страницы сайта для подключения ЮKassa (2026-09-27)

**Источник публичных страниц — `app/web/legal/`** (Flutter копирует `app/web/**`
в `build/web` при сборке); `docs/legal_index.html` удалён (источник переехал).
В корень сайта: `app/web/privacy.html` (`/privacy.html`) и
`app/web/cookies.html` (`/cookies.html`) — так их адресуют собственные тексты.

- `legal/index.html` — реквизиты **ИП Каратеева И. О.** (ИНН 332905240930,
  ОГРНИП 326330000052193, тел. +7 993 600-19-80) + контакты + ссылки на
  документы. **Ссылка для формы ЮKassa → https://prepressplan.ru/legal/**
- `legal/pricing.html` — тарифы с фиксированными ценами (Free / Pro 5000 ₽ /
  50000 ₽) + «Как оплатить» + «Порядок получения услуги» (электронная услуга,
  доступ автоматически после платежа ЮKassa) — закрывает требования ЮKassa
  «товары/услуги/цены», «способы получения», «контакты».
- `legal/terms.html` — публичная оферта (ст. 437/438 ГК РФ, возврат, реквизиты).
- `privacy.html` — Политика 152-ФЗ: markdown-таблица оператора в HTML-таблицу
  (в `docs/privacy_policy.html` тоже исправлено). Почта обращений
  `info@prepress.ru` — реальный домен prepress.ru, оставлено как в Политике.
- In-app юрэкран (`legal_screen.dart`): плейсхолдеры (ООО «Препресс-Технологии»,
  ИНН 770712345678, «ул. Примерная», телефон +7 (495) 000-00-00, фиктивные
  банковские реквизиты) заменены на данные ИП; блок банковских реквизитов
  удалён (оплата — картой через ЮKassa).

**Проверки:** `flutter analyze` 0, `flutter test` 51/51, `flutter build web` —
страницы в `build/web/{legal/,privacy.html,cookies.html}`; греп по
плейсхолдерам чист.

**Важно (для подачи в ЮKassa):** DNS `prepressplan.ru → 193.233.193.12 (vps2)`,
но сейчас там живёт **Cleaning Ops** (k3s) — до деплоя «Препресс-Планера»
на этот домен страницы по ссылкам формы отдаваться не будут; вкладку
«Реквизиты» приложения ждать тоже не нужно. Затем — боевой TLS
(`get_prod_certs.sh`, §9 п.1).

---

## 16. Прод на k3s: 185.227.144.229 (2026-09-27)

**Решение заказчика:** сервер зачищен от старых стеков (cleaning-ops/docker —
тома сохранены), «Препресс-Планер» развёрнут **всем в Kubernetes** (k3s).

- **Конфликт, который к этому привёл:** k3s ServiceLB (`svclb-traefik`) занял
  80/443 на уровне nft (hostPort DNAT): ВЕСЬ трафик портов (включая
  docker-proxy) уходил в Traefik — compose-edge оказался невостребован.
- **Манифесты:** `deploy/k8s/` (namespace `prepress`, ConfigMap, секреты
  генерирует `k8s/apply.sh`, PVC на local-path, 8 сервисов, Ingress +
  ClusterIssuer `letsencrypt-prod` HTTP-01 через Traefik). Образы `pp-*`
  собираются docker'ом и импортируются: `k3s ctr images import`.
  Edge-nginx как под `web` (образ `pp-web`: SPA + `nginx-k8s.conf`,
  plain HTTP; TLS у Traefik).
- **Приёмка (через Traefik, Host: prepressplan.ru):** все 9 подов Ready;
  `/healthz` → nginx-edge; `/auth/devices` → 401; `/legal/`, `/legal/pricing`
  → 200; сквозной путь `POST /auth/register 201 → POST /api/projects 201 →
  POST /calculate` → **эталон 1:1 (9×5, 5040, 26.18 %, 704.88 ₽)**.
- **Уроки:** init-контейнер ждать зависимости обязан с `nc -w 2` (без
  таймаута — зависание на SYN-drop до ~15 мин); pull образов из Docker Hub
  на этом сервере медленный (2–3 мин на образ).
- **Остаётся:** DNS A `prepressplan.ru → 185.227.144.229` (через API reg.ru,
  доступ у заказчика) → cert-manager выпустит LE-сертификат автоматически;
  `kubectl -n prepress get certificate prepressplan-tls`.
  compose-стек на сервере остановлен (`docker compose down`, тома целы).

### 16.1 DNS + боевой TLS (2026-09-27, закрыто)

- **DNS**: A `@`/`www prepressplan.ru → 185.227.144.229` изменены в панели
  хостинга (ispmanager `server125.hosting.reg.ru:1500`, логин `u3638907`).
  API reg.ru недоступен извне (`ACCESS_DENIED_FROM_IP` + методы zone/*
  только для партнёров) — правки делались через панель. Удалены AAAA `@` и
  `www` (у нового сервера нет v6-LB Traefik — v6-клиенты уходят по A);
  почтовые/ftp-записи (mail/smtp/pop/ftp A+AAAA → старый VPS) и MX/TXT/NS
  не тронуты.
- **TLS**: cert-manager ClusterIssuer `letsencrypt-prod` (HTTP-01 через
  Traefik) → сертификат **Let's Encrypt выпущен** (CN=prepressplan.ru,
  до 26.12.2026, secret `prepress/prepressplan-tls`).
  Ловушка: self-check висел на кэшах DNS (CoreDNS отдавал старый A) —
  лечится `rollout restart -n kube-system deploy/coredns`; кэш
  systemd-resolved — `resolvectl flush-caches`.
- **Приёмка по HTTPS**: `/` → 200, `/healthz` → nginx-edge, `/legal/` → 200,
  `/auth/devices` → 401, цепочка доверия валидна.
- Ссылки для формы ЮKassa рабочие: `https://prepressplan.ru/`,
  реквизиты `https://prepressplan.ru/legal/`.

### 16.2 Правки после запуска прода (2026-09-27)

- **Цены Pro**: 990/9900 → **5000 ₽/мес, 50000 ₽/год** везде: paywall
  (приложение), лицензионные тексты, `pricing.html`, оферта `terms.html`,
  дефолты `payments/config.py`, README, манифест `deploy/k8s/21-billing.yaml`.
  Живой прогон: `GET /payments/plans` → month 5000 / year 50000; страница
  тарифов обновлена (rollout billing + pp-web пересобран).
- **Копирайт**: во всех футерах сайта «© 2026 Препресс-Планер» (без
  «ИП Каратеева»). Реквизиты, текст оферты и Политика ИП НЕ тронуты —
  они остаются юридическими сведениями.
- **Почтовые ящики** `@prepressplan.ru` созданы в ispmanager-панели
  (server125): info, support, billing, dpo (пароли выданы заказчику в чате).
  Почтовый домен настроен автоматически, DKIM/DMARC TXT-записи панель
  добавила в зону сама (проверено у ns1.hosting.reg.ru); SPF был ранее.

### 16.3 SMTP и бэкапы в k3s (2026-09-27)

- **SMTP** настроен на хостинге reg.ru: `mail.hosting.reg.ru:587` (STARTTLS,
  AUTH проверен — `235 OK`), логин/отправитель `info@prepressplan.ru`
  (пароль — как у почтового ящика). В ConfigMap `pp-config` (01-config.yaml),
  rollout auth → healthz `"smtp": true`. Сброс пароля и письма-приглашения
  теперь реально отправляются; финальное тестовое письмо — заказчику.
- **Бэкапы**: compose-скрипт заменён в k8s на `deploy/k8s/backup.sh`
  (kubectl exec pg_dump + tar-зеркало MinIO + опциональный offsite по
  `PP_OFFSITE_*`). Живой тест: дамп БД + 18 файлов bucket. **Cron на сервере**:
  `0 4 * * *` → `/var/log/pp-backup.log`, каталог `deploy/backups/`
  (в .gitignore). Восстановление — в шапке скрипта.

---

## 17. Состояние на конец сеанса (2026-09-28)

**Аккаунты на проде (auth в k3s, ns=prepress):**
- **`info@prepressplan.ru` / `Info_Pp2026!`** — основной рабочий/тестовый
  аккаунт: триал Pro активен, тот же пароль что у почтового ящика (SMTP
  подтверждён письмом). Рекомендуется для личной проверки.
- `k8s-accept-1790523361@example.com` / `Accept2026` — приёмочный (есть
  проект «k8s-приёмка» с эталонным расчётом).
- `pdf-fix*@example.com` / `PdfFix2026` — одноразовые под проверку PDF.

**Git:** ветка `main` **ahead origin на 8 коммитов** (e7fe959…2399cc2) —
push НЕ делался (ждёт санкции владельца). Дерево чистое.

**Прод:** https://prepressplan.ru — k3s `prepress` (185.227.144.229),
Let's Encrypt до 26.12.2026 (автопродление cert-manager),8/8 подов.
SMTP `mail.hosting.reg.ru:587` (auth healthz smtp:true). Бэкапы: cron 04:00
(`deploy/k8s/backup.sh`, лог /var/log/pp-backup.log). Цены Pro 5000/50000.

**Открытые направления (по приоритету):**
1. ~~Форма ЮKassa → ключи → rollout billing~~ — **КЛЮЧИ ПОДКЛЮЧЕНЫ**
   (§20, VERIFICATION §15): `/v3/me` 200, живой checkout создаёт платёж.
   Остаётся внешнее: регистрация вебхука
   `https://prepressplan.ru/payments/webhook` (секрет в `pp-secrets`) и
   тестовая оплата — статус приходит только вебхуком.
2. ~~Push 8 коммитов~~ — **СДЕЛАНО**: `git fetch` 2026-09-28, `origin/main`
   синхронизирован с локальным `main` (0/0).
3. Идентификация домена .ru через Госуслуги (предупреждение reg.ru;
   продление 08.09.2027).
4. Юр.просмотр оферты `/legal/terms.html`.
5. Offsite-бэкапы: нужен внешний S3 (`PP_OFFSITE_*` готовы).
6. ~~Drill-восстановления из бэкапа~~ — **ЗАКРЫТО** 2026-09-28 (§18):
   restore прогнан в scratch-ресурсах, пробел с `auth.db` найден и исправлен.
7. Мониторинг/алерты healthz (на сервере уже есть prometheus, ns
   `monitoring`; при дрилле поймано: `/healthz` >1 с под нагрузкой при
   дефолтном `timeoutSeconds: 1` проб → флокают readiness/liveness —
   см. VERIFICATION §11.5); UI участников (F-19 API есть, экрана нет);
   iOS IAP (ждёт Apple-аккаунт).
8. SMS-провайдер подтверждения телефона (§19): сейчас `PP_SMS_PROVIDER=dev`
   (код в ответе) — до публичного запуска подключить (DEPLOY_CHECKLIST
   «Внешние действия» п.5); деплой auth-образа и манифестов на прод.

**Навыки сеанса:** Pdf-фикс §5 (baseline-семантика pdf_writer), SMTP через
хостинг, ispmanager-панель u3638907 (server125), k3s + Traefik edge;
Read-инструмент периодически отдаёт чужие картинки — проверять пикселями.

---

## 18. Дрилл-восстановление из бэкапа (2026-09-28)

П.6 §17 закрыт — полный отчёт с фактами: `docs/VERIFICATION.md` §11.

- **Восстановление проверено изолированно** (scratch-поды `pg-drill`,
  `auth-drill`, `minio-drill` на проде; прод не изменялся, поды удалены):
  PostgreSQL → RESTORE_OK, 9/9 таблиц и diff данных 1:1; MinIO → boot с
  зеркала, 24/24 файла sha256 = live, 18/18 S3-ключей, GET объекта
  байт-в-байт с живым.
- **Пойман пробел и исправлен:** `backup.sh` не брал `auth.db` (аккаунты,
  PVC `auth-data`) и `billing-data` — восстановление теряло бы пользователей.
  Добавлен шаг `2/4` (онлайн-снимок SQLite через `sqlite3 backup()` в
  контейнере auth + tar billing); проверен: восстановленный `auth.db` —
  6/6 таблиц и схема 1:1.
- **Наблюдение (в §17 п.7):** `/healthz` под нагрузкой отвечает >1 с, а пробы
  без `timeoutSeconds` дают дефолт 1 с — readiness/liveness флокают;
  на узле уже стоит prometheus (ns `monitoring`) для алертов (VERIFICATION §11.5).
- **Инструменты в репо:** `deploy/k8s/drill-pg.yaml`, `drill-minio.yaml`,
  правленый `backup.sh` (шаги 1/4…4/4 + команды восстановления в шапке),
  `deploy/k8s/README.md` (раздел бэкапов).
- **Доказательства на сервере:** `/opt/pp/drill/20260928_170327` (baseline)
  и `20260928_171733` (с фиксом). Крон 04:00 подхватит новые шаги сам.
- Остались внешние: offsite S3-бэкет (п.5), ЮKassa-ключи (п.1) и пр.
  (список — §17).

---

## 19. Регистрация с подтверждением почты и телефона (2026-09-28)

Заказчик поставил задачу верификации при регистрации. Решения владельца:
двухфазная схема register→confirm, SMS — dev-режим до подключения
провайдера, существующие аккаунты помечены подтверждёнными.
Подробности и прогоны: `docs/VERIFICATION.md` §12; контракт —
`services/auth/README.md` (v0.4.0).

**Суть:** `POST /auth/register` (теперь **обязательный `phone`**) → 202
без сессии + два кода (email по SMTP, телефон — `PP_SMS_PROVIDER=dev`) →
`POST /auth/confirm` → 201 сессия; `login` до confirm — 403;
`confirm/resend` с кулдауном 60 с. Клиент: поле телефона и экран
«Подтверждение регистрации» (`account_screen.dart`, контроллер
`needsConfirm`). Миграция БД: `users.phone`/`*_verified_at` (одноразовый
backfill) + таблица `verify_codes`.

**Изменения в дереве (не закоммичены):** services/auth (main.py, tests,
README), app (account_client, license_controller, account_screen,
license_account_test), deploy (.env.example, docker-compose, k8s
01-config/20-auth, DEPLOY_CHECKLIST), docs (VERIFICATION §12, этот файл).

**Прогоны (зелёные):** pytest **161 passed, 1 skipped**; flutter analyze 0,
test **52/52**, build web OK; `docker compose config` OK; kubectl
`--dry-run=client` манифестов OK.

**Осталось внешнее:** подключить SMS-провайдер (`_send_sms` +
`PP_SMS_PROVIDER`, DEPLOY_CHECKLIST «Внешние действия» п.5) — до этого
на проде dev-режим: SMS-код виден в ответе. Деплой на прод (образ auth +
применение манифестов) — после санкции владельца.

**Деплой (2026-09-28, после коммита `0339ddd`):** образы `pp-auth`/`pp-web`
собраны на сервере и импортированы в k3s, `01-config.yaml` +
`20-auth.yaml` применены, rollout auth+web Successful; живой прогон на
`prepressplan.ru` — 202/403/400/201/409/200 + resend 429, миграция
7/7 verified, тестовый юзер удалён (VERIFICATION §12.4).

**1/1-вытеснение (2026-09-28, позже в тот же день):** владелец сообщил,
что simultaneous-вход комп+телефон работает — лимит был удалён ещё при
SaaS-адаптации, UI обещал 1/1. Возвращено: `login`/`confirm` отзывают
прежние сессии, `device_policy` → `single` (VERIFICATION §13).

**Реакция клиента на вытеснение (2026-09-28, §13.2):** жалоба «оба
устройства выглядят залогиненными» — сервер держал 1 сессию, клиент не
сбрасывал локальную при 401. `LicenseController`: 401 в
`_refreshFromServer`/`devices` → `_dropSession()`; `pp-web` выкачен;
свип старых дублей сессий (теперь 1 на аккаунт). Тесты 54/54.

**Проверка сессии на вкладках (2026-09-28, §13.3):** `ensureSession()`
(`GET /auth/me`) вызывается из `HomeShell._selectTab`/`_setProject` —
401 → мгновенный разлогин без перезагрузки; фикс assert `Material` в
legal-вкладке. Тесты 56/56.

**Эскиз ТЭО (2026-09-28, VERIFICATION §14):** подпись габарита в графе 6
при узких этикетках вылезала за бокс — фит-условие + вывод под бокс;
регрессионный тест парсит PDF-поток (без фикса падает). Домен/e2e/
domain-worker зелёные; `pp-domain-worker` выкачен (`62f6551`), живой
отчёт на проде проверен (VERIFICATION §14).

## 20. ЮKassa: ключи подключены (2026-09-28)

Секретный ключ и `shop_id=1453145` — в `pp-secrets` (в git нет;
`21-billing.yaml` → secretKeyRef). `/v3/me` → 200, billing
`configured: true`, живой checkout создал платёж (см. VERIFICATION §15).
Осталось владельцу: зарегистрировать вебхук
`https://prepressplan.ru/payments/webhook` (секрет — `YUKASSA_WEBHOOK_SECRET`
в `pp-secrets`) и провести тестовую оплату — статус приходит только
вебхуком.

**Вебхук ЮKassa (§20 продолжение, VERIFICATION §16):** кабинет — раздел
«Интеграция → HTTP-уведомления» (вкладки «Webhooks» нет), форма заполнена
владельцем. ЮKassa не шлёт HMAC — billing переведён на сверку объекта
через API (GET /payments|/refunds/{id} + статус); подпись опциональна.
Payments 57 тестов, полный pytest 167. Осталось: деплой billing + живая
проверка + оплата владельцем.

**Paywall «not found» (2026-09-28, VERIFICATION §17):** покупка звала
удалённый `/payments/orders/{id}/confirm` → 404. Теперь checkout →
открытие `confirmation_url` (`LicenseController.openUrl`), подтверждение —
вебхук; `ensureSession` при возврате фокуса подтягивает подписку. Тесты
57/57.

## 21. SMS.ru: реальный провайдер подтверждения телефона (2026-09-28)

Адаптер готов (`PP_SMS_PROVIDER=sms_ru`, api_id в `PP_SMS_API_ID`;
test=1 через `PP_SMS_TEST`); dev_phone_code теперь только в dev-режиме.
Тесты 170. Осталось: api_id владельца → секрет → включение → живая
отправка (VERIFICATION §18, DEPLOY_CHECKLIST п.5).

**Регистрационные данные (2026-09-28, VERIFICATION §19):** обязательное
`name` в register (миграция `users.name`, отдаётся в user-объектах),
форма: имя/почта/телефон/пароль/подтверждение пароля (валидация на
клиенте). Тесты 171 + flutter 58.

**SMS-включение (2026-09-28):** api_id в `pp-secrets`, `sms_ru` +
`PP_SMS_TEST=1` в ConfigMap, auth/web выкачены. Смоук упёрся в код 221
(нужен буквенный отправитель в кабинете sms.ru) — добавлен
`PP_SMS_FROM`; смок-юзер удалён. Дальше: отправитель → смоук → test=0 →
реальный SMS (VERIFICATION §18).

**UI-правки (2026-09-28, VERIFICATION §20):** юр. вкладка и футер-ссылка
убраны (копирайт = ссылка на /legal, legal_screen удалён); `openPaywall`
без входа открывает сначала вход — окно биллинга только авторизованным
(сервер checkout и так за Bearer). Тесты 59/59.

## 22. Админ-панель: отдельный сервис (2026-09-29)

Запрос владельца: админка отдельным сервисом, доступ по роли admin/owner,
полный набор. Реализован `services/admin` (:8130, HTML без сборки):
гейт = owner/admin **системной организации (первой по created_at)**;
обзор healthz, аккаунты (revoke/delete), доступы (прокси auth, роли
member/viewer/admin — `MemberAddIn` расширен), подписки grant/revoke Pro,
заказы, read-only БД (whitelist). Инфраструктура: `/admin` в 3 nginx,
compose-сервис, `k8s/25-admin.yaml`, CI-шаг. Тесты admin 9/9, полный
pytest **180 passed** (VERIFICATION §21).

**На проде:** системная организация — org «k8s-accept…» (owner
`k8s-accept-1790523361@example.com`); после деплоя в system org добавить
`info@prepressplan.ru` (admin), иначе владелец не войдёт. URL:
`https://prepressplan.ru/admin/`.
