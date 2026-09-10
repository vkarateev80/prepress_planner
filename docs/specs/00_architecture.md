# 00. Архитектура «Препресс-Планер»

**Статус: актуален на 2026-09-07 (HEAD bed533e)**

> Ветка `master`, коммит `bed533eb698b333ae2cd067be5d5ff91261db0e5`.
> Утверждения проверены чтением кода; ссылки — `путь/файл:строка`.

---

## 1. Контекст, цели, платформы

**Что это.** Приложение препресс-планирования расходных материалов и
технико-экономического обоснования (ТЭО) тиражей этикеток
(`docs/HANDOFF.md:16-17`).

| № | Задача | Где реализовано |
|---|---|---|
| 1 | Импорт задания (DXF/SVG/PDF/AI; AI/CDR/EPS — через сервис) | `packages/core/lib/src/parser/parse_file.dart:23`; `app/lib/src/converter/converter_api.dart:73` |
| 2 | Анализ технологичности и лечение геометрии | `packages/core/lib/src/manufacturability/analyzer.dart:39,84` |
| 3 | Массив «мастер + закон», генерация сетки | `packages/core/lib/src/optimizer/pattern_recognition.dart:83`; `.../array_generator.dart:39` |
| 4 | Расчёт расхода материала | `packages/core/lib/src/calculator/material.dart:158` |
| 5 | Экономика тиража, 1000 шт, сравнение вариантов | `packages/core/lib/src/economics/teo.dart:112,214` |
| 6 | Отчёты PDF/XLSX/DXF | `.../reports/teo_report.dart:81`; `.../teo_xlsx.dart:197`; `.../dxf_writer.dart:29` |
| 7 | Аккаунты, подписка Pro, триал | `services/auth/auth_app/main.py:299`; `services/payments/payments_app/main.py:48-50` |

**Вне объёма намеренно.** УФ-маска и генерация УП/G-кода удалены из новой
версии, остались только в легаси-эталоне (`docs/HANDOFF.md:23-25`); в
`packages/core` не появляются — греп-контроль (`docs/HANDOFF.md:146-148`).

| Платформа | Состояние (2026-09-07) |
|---|---|
| Windows / Linux (desktop) | собрано и работает; тяжёлые вычисления — в изоляте (`app/lib/platform/isolates_io.dart:6`) |
| Web | собрано и развёрнуто: `flutter build web` + nginx единый origin |
| iOS / macOS | код кроссплатформенный, бинари **не собирались** (`docs/HANDOFF.md:18-22`) |

Различия платформ инкапсулированы в `app/lib/platform/*` условным импортом
`import 'X_io.dart' if (dart.library.html) 'X_web.dart'` — шесть пар
реализаций: `json_store.dart:9-10`, `env.dart:4`, `http.dart:11-12`,
`files.dart:7`, `save_out.dart:8`, `isolates.dart:5`.

---

## 2. Схема репозитория

```
<корень>/                    git, ветка master, HEAD bed533e
├── README.md · SECURITY.md · РУКОВОДСТВО_ПОЛЬЗОВАТЕЛЯ.{md,pdf}
├── packages/core/            ЧИСТЫЙ Dart-домен (без Flutter; dependencies: {})
│   ├── lib/prepress_core.dart  баррель (io.dart НЕ экспортируется)
│   ├── lib/io.dart             файловый фасад: parseFile, шрифт, запись отчётов
│   ├── lib/src/                model, geom (polygon2/geom_ops/geom_boolean + bbox-сетки),
│   │                           parser (dxf/svg/pdf/ai_pdf/inflate/parse_file),
│   │                           healer/morphology, optimizer, calculator,
│   │                           manufacturability, economics, reports
│   ├── test/*_test.dart      16 исполняемых тест-скриптов (void main())
│   └── tool/                 e2e.dart (эталон), profile_heal, stat_analyze
├── app/                      Flutter (Windows/Linux desktop + Web)
│   ├── lib/main.dart         вход; LicenseController + MaterialLibrary со старта
│   ├── lib/src/              screens (home_shell, projects, geometry, layout, teo, reports),
│   │                         projects/project.dart (JSON v2), materials, converter, logs
│   ├── lib/platform/         io/web: env, json_store, files, save_out, http, isolates
│   ├── lib/license/          license_client, account_client, entitlement_store,
│   │                         license_controller, paywall_screen, account_screen
│   ├── assets/fonts/DejaVuSans.ttf  кириллица для PDF (rootBundle)
│   └── test/                 11 файлов (widget, license, account, converter, web-смоук)
├── services/                 FastAPI: converter :8120 (AI/CDR/EPS → SVG/PDF),
│                             auth :8121 (аккаунты, сессии, 1/1), payments :8122
│                             (тарифы, заказы, Pro — оплата заглушка),
│                             license (офлайн-лицензии; в прод-стек НЕ входит)
├── deploy/                   docker-compose (converter/auth/payments/web-nginx :8081),
│                             nginx/pp-web.conf, .env.example, install_new_server.sh,
│                             build_bundle.{ps1,sh}
├── scripts/run_domain_tests.{ps1,sh} · .github/workflows/{ci,release}.yml
├── fixtures/ · samples/ · test/golden/   эталонные файлы и артефакты
├── agents/00..14.md          ИСТОРИЧЕСКИЕ контракты субагентов (+ README.md)
└── docs/  HANDOFF.md · VERIFICATION.md · specs/ (ЭТОТ НАБОР) · superpowers/
```

Легаси-эталон **вне git** (`.gitignore`): `cam_pipeline/`, `cam_material/` —
Python-код (shapely/ezdxf/PyMuPDF) как оракул сверки (`docs/HANDOFF.md:77-79`).

---

## 3. Слои и границы

```
  ┌─────────────────────────────────────────────────────────┐
  │ UI (Flutter)   app/lib/**  экраны, состояние, io/web    │
  └──────────────┬───────────────────────┬──────────────────┘
                 │ импорт домена         │ HTTP
                 ▼                       ▼
  ┌──────────────────────────┐  ┌──────────────────────────┐
  │ ДОМЕН packages/core      │  │ СЕРВИСЫ services/*       │
  │ чистый Dart, stdlib      │  │ FastAPI + SQLite/файлы   │
  └──────────────────────────┘  └────────────┬─────────────┘
                                             │ docker compose
                                ┌────────────▼─────────────┐
                                │ ДЕПЛОЙ deploy/  nginx,   │
                                │ bundle, install script   │
                                └──────────────────────────┘
```

| Граница | Правило | Чем обеспечено |
|---|---|---|
| Домен → ничего внешнего | без Flutter, UI и сети | `packages/core/pubspec.yaml:10-12` (`dependencies: {}`) |
| Домен: ядро без ФС | байтовые функции в `lib/src/**`, «путевые» — только `lib/io.dart` | `parse_file.dart:8-9`; `io.dart:1-3` |
| UI → домен | через баррель `prepress_core.dart` (+ `io.dart` на VM) | `app/lib/src/projects/project.dart:6` |
| UI → сервисы | только HTTP, без доступа к БД сервисов | `converter_api.dart`; `app/lib/license/account_client.dart` |
| Web не тянет `dart:io` | `io.dart` не в барреле; различия — условный импорт | `prepress_core.dart:1-38`; `app/lib/platform/*.dart` |
| Сервисы изолированы | свой контейнер и каталог данных, общение по именам compose | `deploy/docker-compose.yml:15-93` |

---

## 4. Потоки данных

### 4.1. Импорт → отчёты (основной поток)

```
файл задания
  ├─ .dxf .svg .pdf ─────────────────┐
  └─ .ai .cdr .eps → конвертер ──────┤  (AI, PDF-совместимый, идёт как PDF)
     POST /convert → GET /convert/{id} → download result_url (SVG)
                                     ▼
                 parseBytes(Uint8List, name)              parse_file.dart:23
                     │
      ┌──────────────┴───────────────┐
      ▼                              ▼
analyzeManufacturability      healGeometry            analyzer.dart:39 / :84
(open/dust/intersection/      MorphologicalHealer →
 duplicate/sharp/gap)         TopologicalOptimizer
      └──────────────┬───────────────┘
                     ▼
     PatternRecognizer().analyze()      pattern_recognition.dart:83  (MASTER / ARRAY)
                     ▼
     generateArrayGrid()                array_generator.dart:39
                     ▼
     computeMaterialAuto()  material.dart:279 · enumerateVariants()  layout_optimizer.dart:20
                     ▼
     computeConsumption()   consumption.dart:35
                     ▼
     computeTeo() / compareTeoVariants()   teo.dart:112 / :214
                     ▼
     TeoReportData          report_models.dart:14
                     ▼
     buildTeoReportPdf  teo_report.dart:81  → 04_ТЭО_Отчёт.pdf
     buildTeoXlsx       teo_xlsx.dart:197   → 05_Расчёт.xlsx
     buildDxfText       dxf_writer.dart:29  → 02_Вылеченный_Мастер.dxf, 03_Раскрой.dxf
                     ▼
     saveReport()  save_out.dart:10   desktop → файл; web → скачивание браузером
```

Генераторы отчётов **чистые** (байты → байты,
`packages/core/lib/src/reports/teo_report.dart:79-86`), ввод-вывод вынесен в
платформенный `saveReport` — поэтому генерация идёт в изоляте на desktop и на
главном потоке в браузере (`app/lib/src/screens/reports_screen.dart:1-8,71-87`).
Имена файлов — `02_data_formats.md`, §8.

### 4.2. Аккаунт и подписка

```
UI (account_screen / paywall_screen)
 │ AccountGatewayHttp                                   account_client.dart:144
 ├─ AuthApi     → PP_AUTH_URL     (дефолт desktop http://193.233.193.12:8121)  :201-202
 └─ PaymentsApi → PP_PAYMENTS_URL (дефолт desktop http://193.233.193.12:8122)  :326-327
   ├─ POST /auth/register {email, password, device_id} → {token, user}  auth main.py:239-242,299
   ├─ POST /auth/login    {email, password, device_id} → {token, user}  auth main.py:245-248,316
   ├─ POST /auth/verify   (внутренний; вызывает payments)               auth main.py:369-379
   ├─ POST /payments/checkout {plan} → {order_id, amount_rub, status}   payments main.py:146-164
   └─ POST /payments/orders/{id}/confirm → Pro                          payments main.py:167-189
   ▼
SQLite в PP_DATA_DIR; сессия — opaque-токен, в БД только sha256
(auth main.py:128-148), TTL 720 ч (:55). Клиент кэширует session.json /
entitlement.json (02_data_formats.md, §4-5).
```

Пароли — PBKDF2-SHA256, 200 000 итераций, соль 16 байт
(`services/auth/auth_app/main.py:110-114`). **Оплата — заглушка**: `confirm`
помечает заказ оплаченным без провайдера
(`services/payments/payments_app/main.py:167-189`) — находка К-4
(`SECURITY.md:20`).

### 4.3. Web — единый origin

```
браузер ──HTTP──▶ nginx :8081 ──┬─ /               → статика Flutter (SPA)
                                ├─ /convert, /data → converter:8120
                                ├─ /auth           → auth:8121
                                ├─ /payments       → payments:8122
                                └─ /healthz        → converter:8120
```

Конфиг — `deploy/nginx/pp-web.conf:11-38`; сервисы адресуются **по именам**
compose, CORS не нужен (`deploy/docker-compose.yml:13-14`). На web переменных
окружения нет — `envOrDefault` всегда `''` (`app/lib/platform/env_web.dart:6`),
поэтому клиентские адреса относительные и попадают в тот же origin. Выбор файла
и скачивание отчётов — браузерные (`save_out_web.dart:8-9`; `files_web.dart`).

### 4.4. Desktop

```
запуск exe
 ├─ env PP_CONVERTER_URL / PP_AUTH_URL / PP_PAYMENTS_URL  env_io.dart:8-11
 │     (Platform.environment; дефолты http://193.233.193.12:8120-8122)
 ├─ локальный конвертер: ConverterServer.probe() → /healthz  converter_server.dart:37-45
 │     uvicorn поднимается только для локального адреса
 │     (isLocal: 127.0.0.1 / localhost / ::1 / 0.0.0.0)      converter_server.dart:26-34
 ├─ тяжёлые вычисления — Isolate.run                          isolates_io.dart:6
 ├─ данные: app/projects/*.json (проекты и отчёты), app/state/* (сессия,
 │     энтайтлмент, материалы, machine_id)
 └─ отчёты — файлом; чтение и выбор файла — по путям
```

---

## 5. Принятые решения и обоснования

| № | Решение | Обоснование | Где в коде |
|---|---|---|---|
| 1 | Чистый Dart + stdlib в домене | `pub.dev` недоступен; домен не зависит от Flutter → тесты скриптами | `packages/core/pubspec.yaml:9-12` |
| 2 | Собственный генератор PDF 1.4 | внешних библиотек нет; кириллица — внедрение TTF (`FontFile2`, `Type0/CIDFontType2`, `Identity-H`, `/ToUnicode`) | `reports/pdf_writer.dart:1-11` |
| 3 | Свой inflate | PDF-потоки `/FlateDecode` без внешнего `archive` | `parser/inflate.dart:149,172` |
| 4 | JSON со `schemaVersion: 2` | простота + путь аддитивной миграции | `app/lib/src/projects/project.dart:103` |
| 5 | Единый origin вместо CORS | нет preflight; адреса сервисов не попадают в web-сборку | `deploy/nginx/pp-web.conf`; `env_web.dart:6` |
| 6 | Материалы пользователя в `<state>/materials.json` | каталог-пример не редактируется и всегда в начале списка | `app/lib/src/materials/material_library.dart:1-10,31-39` |
| 7 | Изоляты на desktop, главный поток на web | нет подвисания UI; в браузере изолятов нет — API один | `isolates_io.dart:6`; `isolates.dart:5-7` |
| 8 | Различия платформ — условный импорт | web не видит `dart:io`; UI не ветвится по платформе | `app/lib/platform/*.dart` |
| 9 | Относительные импорты внутри `lib/io.dart` | VM считает `package:`- и file-импорт **разными** → две копии классов и `ParserException` | `packages/core/lib/io.dart:16-19` |
| 10 | Тесты домена — скрипты, не пакет `test` | `test` требует pub-зависимости | `packages/core/test/*.dart`; `docs/HANDOFF.md:41` |
| 11 | bbox-сетки для производительности | полный перебор пар давал 90–280 с; сетка снимает квадратичность при том же результате | `2f1513c`; `geom_boolean.dart:174-175,345` |
| 12 | Журнал событий `AppLog` (в памяти) | ошибки UI нужно видеть и копировать целиком | `app/lib/src/logs/app_log.dart:24-33,94-112` |

---

## 6. Ключевые инварианты и ограничения

| № | Инвариант | Где |
|---|---|---|
| 1 | Координаты — **мм, ось Y вверх**; кривые дискретизированы | `model/cam_path.dart:3-4` |
| 2 | DXF — единицы `$INSUNITS` (по умолчанию 4 = мм) | `parser/dxf_parser.dart:43-63` |
| 3 | SVG — 25.4/96 мм/ед (или `width_mm/viewBox`), Y инвертируется | `parser/svg_parser.dart:3-6,18` |
| 4 | PDF — pt→мм 25.4/72, Y от высоты `MediaBox` | `parser/pdf_parser.dart:1-7,20` |
| 5 | Раппорт = `Z·CP`; `stepY = rapport/r`, `gapY ≥ minGap` | `calculator/material.dart:40-43,181-187` |
| 6 | Колонки ограничены `min(cylWidth, webWidth)` | `calculator/material.dart:189-208` |
| 7 | `count`: `revs = ceil(N/perRev)`; `length`: `revs = floor(L/rapport)` | `calculator/material.dart:212-230` |
| 8 | `runTime = length/(speed·1000)/60` **часов** (м/мин, не м/ч) | `economics/teo.dart:7-13,127-131` |
| 9 | Округления: координаты 4 знака, деньги 2, время 4 | `model/vec2.dart:26`; `economics/teo.dart:5` |
| 10 | В `packages/core` нет УФ-маски и G-кода | `docs/HANDOFF.md:146-148` |
| 11 | Баррель домена не содержит `io.dart`; домен без внешних зависимостей | `prepress_core.dart:1-38`; `pubspec.yaml:10` |
| 12 | .ai/.cdr/.eps локально не разбираются | `parser/parse_file.dart:37-46` |
| 13 | Кириллица в PDF — внедрённый TTF; транслитерация — только fallback | `reports/teo_report.dart:14-36` |

**Ограничения среды.** PowerShell/песочница на Windows не позволяет пайпить
вывод нативных команд; файлы — только UTF-8 (`docs/HANDOFF.md:246-263`).

---

## 7. Точки расширения

| Что расширяем | Точка входа |
|---|---|
| Новый формат импорта | `parser/base_parser.dart:8` + ветка в `parse_file.dart:23-47` |
| Новый движок конвертации | `services/converter/converter_app/convert.py:137-204` |
| Новая машина / материал | данные, не код: `economics/price_catalog.dart:26-108`; `material_library.dart:84-111` |
| Новый отчёт | `reports/report_models.dart:14` + `reports_screen.dart:181-262` |
| Новая статья затрат | `economics/teo.dart:32-106` (`TeoInput` / `TeoResult`) |
| Новая проверка технологичности | `manufacturability/geometry_checks.dart` + `analyzer.dart:49-55` |
| Новый тариф | `services/payments/payments_app/main.py:48-50` (`PLANS`) |
| Новая платформенная возможность | пара `*_io.dart` / `*_web.dart` + условный импорт (`save_out.dart:8`) |

---

## 8. Открытые вопросы и технический долг

### 8.1. Безопасность — приоритет 1 (`SECURITY.md`)

| # | Находка | Влияние |
|---|---|---|
| К-1 | `POST /auth/forgot` возвращает `dev_code` при ненастроенном SMTP | захват любого аккаунта (`:17`) |
| К-2 | SSH под активным брутфорсом, `PermitRootLogin yes` | компрометация сервера (`:18`) |
| К-3 | Всё по http, порты открыты, desktop ходит на зашитые IP | утечка паролей и токенов, MITM (`:19`) |
| К-4 | Оплата — заглушка, `confirm` без провайдера | Pro бесплатен (`:20`) |
| К-5 | Rate limiting отсутствует во всех сервисах | брутфорс логина и reset-кода (`:21`) |

Исправления **отложены заказчиком** (`SECURITY.md:7-9`) — без согласования
серверную конфигурацию не менять. Нормативные требования —
`docs/specs/08_security.md`, план — `docs/specs/09_roadmap.md`.

### 8.2. Функциональный и инфраструктурный долг

| # | Вопрос | Где зафиксировано |
|---|---|---|
| 1 | Серверного энфорсмента Pro нет: гейтинг клиентский, `state/entitlement.json` редактируем | `SECURITY.md:27` |
| 2 | `services/license` не в прод-композе и клиентом не вызывается; дефолтный секрет — публичная константа | `SECURITY.md:38`; `license_app/crypto.py:77-79` |
| 3 | SMTP / домен / TLS отсутствуют — блокер для `forgot` вне dev | `SECURITY.md:60-61` |
| 4 | Реальный платёжный провайдер не подключён | `SECURITY.md:62` |
| 5 | iOS/macOS: бинари не собирались; для iOS нужен StoreKit/IAP | `docs/HANDOFF.md:292-293` |
| 6 | CI на GitHub не прогонялся (в сервис-джобе `skipif` без Inkscape) | `docs/HANDOFF.md:295-296` |
| 7 | Числа тестов в `docs/VERIFICATION.md` посчитаны по коду, не прогоном | `docs/VERIFICATION.md:132-141` |
| 8 | ~~`docs/HANDOFF.md` описывает снимок `448dcba`, а не текущий `bed533e`~~ — **устранено 2026-09-07**: HANDOFF содержит блок «Обновление после снимка», `README.md` указывает базовую линию `bed533e` | `docs/HANDOFF.md:9-18` |
| 9 | Схема проекта не проверяет `schemaVersion` при чтении | `02_data_formats.md`, §10.1 |

---

## 9. Связанные документы

`01_domain_core.md` (домен и эталонные числа) · `02_data_formats.md` (форматы
и схемы) · `03_app_ui.md` · `04_services_api.md` · `05_platforms_builds.md` ·
`06_deploy_ops.md` · `07_testing_quality.md` · `08_security.md` ·
`09_roadmap.md` · `README.md` (индекс) · `agents/00..14.md` (история) ·
`docs/VERIFICATION.md` · `docs/HANDOFF.md` · `SECURITY.md`.
