# domain-worker — серверный исполнитель домена (ADR-2)

Чистый **Dart VM** (без Flutter и без pub-пакетов) HTTP-сервис, который исполняет
канонический домен `packages/core`: `parse → analyze/heal → pattern → calc →
variants → teo`. Браузер (Flutter Web) остаётся тонким UI-клиентом, вся
математика считается здесь — на том же Dart VM, на котором зелёные
`packages/core/test` и `packages/core/tool/e2e.dart` (ADR-2, N-1).

- Документы-основания: **PRD v2 (§7.2, §10.2)**, **System Design v1 (ADR-2)**,
  уже готовая инфраструктура `projects-cloud` (гибридное хранилище,
  `api:8100`, `domain-worker:8101` — только внутри сети compose).
- Схема обмена и хранения — существующая **`project_state.json v2`**
  (`app/lib/src/projects/project.dart`).
- `packages/core` **не изменяется**: воркер только вызывает его функции.

---

## 1. Структура

```
services/domain-worker/
├── bin/domain_worker.dart        # точка входа: HttpServer :8101 + graceful shutdown
├── lib/
│   ├── domain_worker.dart        # барель пакета (как packages/core/lib/prepress_core.dart)
│   └── src/
│       ├── errors.dart           # WorkerError: русские сообщения, коды, HTTP-статусы
│       ├── params.dart           # LayoutParams/ManufacturingParams/PriceCatalog из JSON
│       ├── state.dart            # project_state.json v2: camPathToJson, issueToJson, …
│       ├── pipeline.dart         # доменная цепочка (вызовы packages/core)
│       ├── request.dart          # разбор и нормализация тела запроса
│       ├── isolate_executor.dart # Isolate.spawn + ограничение параллелизма/таймаут
│       └── server.dart           # маршруты, CORS, Bearer-токен, лимиты тела
├── test/
│   ├── pipeline_test.dart        # эталонные числа, стадии, детерминизм, русские ошибки
│   ├── materials_test.dart       # сериализация v2, круг «геометрия → JSON → геометрия»
│   ├── server_test.dart          # HTTP: /healthz, /calculate, коды, изоляты, токен
│   └── examples/                 # живые примеры вход/выход (генерятся tool/make_examples.dart)
├── tool/
│   ├── verify_reference.dart     # сверка 26.18 % / 2032.0 мм² / 704.88 ₽ (локально и по HTTP)
│   ├── make_examples.dart        # перегенерация test/examples/*
│   └── test_utils.dart           # мини-каркас тестов (копия конвенции packages/core)
├── pubspec.yaml                  # единственная зависимость — path: ../../packages/core
├── analysis_options.yaml
└── .gitignore
```

Dockerfile вынесен в корень репозитория (`Dockerfile.domain-worker`), потому что
`deploy/docker-compose.yml` собирает сервис с контекстом `../` (корень монорепо)
и объявляет том `../packages/core:/workspace/packages/core:ro`.

---

## 2. Подключение `packages/core` (без pub.dev)

Способ — **path-зависимость в `pubspec.yaml`**, резолвится офлайн из локального
каталога, сеть и pub.dev не нужны:

```yaml
dependencies:
  prepress_core:
    path: ../../packages/core
```

Подготовка (один раз, и в Dockerfile тоже):

```bash
cd services/domain-worker
dart pub get --offline          # → .dart_tool/package_config.json, 0 сетевых обращений
dart analyze                    # чисто
dart run bin/domain_worker.dart
```

Проверено на Dart 3.3.4: `dart pub get --offline` проходит и с **пустым**
`PUB_CACHE`, и при заблокированной сети (зависимость только path). Альтернативы,
которые **не** используются, и почему:

| Способ | Почему нет |
|---|---|
| `import '../../packages/core/lib/prepress_core.dart'` | работает, но ломает `package:`-импорты и требует правки путей в каждом файле; вдобавок VM считает такую библиотеку отдельной от `package:prepress_core` (две копии классов и исключений) — см. предупреждение в `packages/core/lib/io.dart` |
| Символическая ссылка | не переносится на Windows/git/Docker-контекст |
| Копия `packages/core` внутрь воркера | дублирование домена: правка эталонной математики перестала бы быть единой (N-1) |

Импорт домена в коде — только `import 'package:prepress_core/prepress_core.dart';`,
внутри воркера — относительные импорты (конвенция `packages/core`).

---

## 3. Запуск

```bash
# локально (dev), порт по умолчанию 8101
cd services/domain-worker && dart pub get --offline && dart run bin/domain_worker.dart

# проверка живости
curl -s localhost:8101/healthz | python3 -m json.tool
```

### Переменные окружения

| Переменная | По умолчанию | Назначение |
|---|---|---|
| `PP_DOMAIN_PORT` | `8101` | порт HTTP (в compose — внутренний) |
| `PP_DOMAIN_HOST` | `0.0.0.0` | адрес прослушивания |
| `PP_DOMAIN_TOKEN` | — (не требуется) | Bearer-токен для POST-маршрутов; `/healthz` открыт (N-2) |
| `PP_DOMAIN_MAX_BODY_MB` | `96` | лимит тела запроса (base64 ≤ 50 МБ файла + состояние) |
| `PP_DOMAIN_CONCURRENCY` | по числу ядер | максимум одновременно работающих изолятов |
| `PP_DOMAIN_TIMEOUT` | `180` с | таймаут одной задачи расчёта |
| `PP_DOMAIN_CORS_ORIGINS` | — | список origin через запятую (dev; в проде вызовы сервер-к-серверу) |

---

## 4. HTTP API

| Метод | Маршрут | Назначение |
|---|---|---|
| `GET` | `/healthz` | healthcheck compose (N-2): статус, версия, схема, стадии. Секретов не содержит |
| `GET` | `/status` | `/healthz` + метрики пула изолятов (`active`, `queued`, `maxConcurrent`), счётчики запросов |
| `GET` | `/` | карта сервиса: маршруты, стадии, эталонные числа |
| `POST` | `/calculate` | доменная цепочка. Алиасы: `/calculation`, `/run`, `/pipeline`, `/v1/calculate`, `/api/calculate` |
| `POST` | `/<стадия>` | одна стадия: `parse`, `analyze`, `heal`, `pattern`, `calc`, `variants`, `teo` |

Все расчёты выполняются в изоляте (`Isolate.spawn`), поэтому приём HTTP-запросов
не блокируется (N-3). Формат ошибки — как у `api`:

```json
{"error": {"code": "geometry_error", "message": "Этикетка шириной 9999.00 мм не влезает в ширину 300.00 мм (цилиндр/полотно).", "details": {"stage": "calc"}}}
```

| Код | HTTP | Когда |
|---|---|---|
| `bad_request` | 400 | структура JSON, типы, неизвестная стадия, пустой запрос |
| `unsupported_format` | 400 | EPS/CDR/неизвестный формат — нужна серверная конвертация (ADR-7) |
| `file_not_found` | 400 | нет макета; `storage_key` без байтов; файл по `file_path` не найден |
| `unauthorized` / `forbidden` | 401 / 403 | `PP_DOMAIN_TOKEN` задан, а заголовка нет/неверный |
| `not_found` / `method_not_allowed` | 404 / 405 | неизвестный маршрут; GET вместо POST |
| `payload_too_large` | 413 | тело больше лимита |
| `geometry_error` | 422 | геометрия/параметры не дают раскроя или ТЭО (`MaterialResult.error`, `TeoResult.error`) |
| `internal` / `timeout` | 500 / 504 | падение изолята; превышен `PP_DOMAIN_TIMEOUT` |

### 4.1 Вход (`POST /calculate`)

Живой пример — [`test/examples/request_full.json`](test/examples/request_full.json)
(полная цепочка по файлу) и [`test/examples/request_minimal.json`](test/examples/request_minimal.json)
(эталонный сценарий PRD §10.2 без файла).

| Поле | Тип | Назначение |
|---|---|---|
| `stages` | `string[]` \| `string` | что считать: `["all"]`, `["calc","teo"]` или одна стадия. По умолчанию — вся цепочка |
| `file_base64` | `string` | байты макета (DXF/SVG/PDF/AI-PDF), чистый base64 **без** data-URL-префикса |
| `file_path` | `string` | путь к файлу внутри контейнера (монтированные каталоги, `PP_DATA_DIR`) |
| `fileName` | `string` | имя файла с расширением (выбор парсера; обязательно для `file_base64`) |
| `storage_key` | `string` | ключ объекта в S3: **метаданные** версии файла. Воркер сам в хранилище не ходит — API присылает байты (см. §7) |
| `rawPaths` \| `appState.rawPaths` | `CamPath[]` | готовая геометрия `{points:[[x,y]…], closed, layer}` — разбор пропускается |
| `params` | `object` | `LayoutParams` (переопределяет `appState.params`) |
| `manufacturingParams` | `object` | `tolerance`, `minLoopArea`, `minRadius`, `minGap` |
| `appState` (синоним `state`) | `object` | текущее состояние проекта: `name`, `inputFile`, `params`, `rawPaths`, … |
| `priceCatalog` | `object` | каталог статей затрат (иначе `PriceCatalog.defaults()`) |
| `teoInput` (синоним `teo`) | `object` | `materialId`, `machineId`, `toolingCost`, `markupPct`, `setupMaterialMeters`, `shiftCostPerShift`, `hoursPerShift`, `shiftsPerDay` |
| `variantsLimit` | `int` | сколько вариантов раскроя вернуть (`0` — без ограничения, по умолчанию `50`) |
| `teoComparisonLimit` | `int` | сколько лучших вариантов сравнивать в ТЭО (по умолчанию `10`) |
| `patternOffsets` | `[[x,y]…]` | готовый закон массива (заменяет авто-сетку `generateArrayGrid`) |
| `masterLayer` / `arrayLayer` | `string` | имена слоёв мастера и массива (`MASTER` / `ARRAY`) |
| `includeRawPaths` | `bool` | `false` — не отдавать исходную геометрию в `state.rawPaths` (экономный ответ) |
| `includeErrors` | `bool` | `true` — дополнительно вернуть тяжёлые данные внутри `stageResults` (списки `Issue`, `items`, `pathsJson`) |

Минимальный запрос (весь эталон PRD §10.2 задаётся параметрами домена по умолчанию):

```bash
curl -s localhost:8101/calculate -H 'content-type: application/json' -d '{
  "stages": ["calc", "teo"],
  "params": {"labelW": 50, "labelH": 30, "gapX": 3, "gapY": 3,
             "zTeeth": 96, "cp": 3.175, "cylWidth": 300, "webWidth": 300,
             "mode": "count", "count": 5000},
  "teoInput": {"materialId": "paper-sa-80", "machineId": "flexo-300"}
}'
```

Полная цепочка по файлу (так зовёт `api`, у которого есть байты из S3):

```bash
B64=$(base64 -i ../../fixtures/quadroring.svg | tr -d '\n')
curl -s localhost:8101/calculate -H 'content-type: application/json' -d @- <<JSON
{"stages":["all"],"fileName":"quadroring.svg","file_base64":"$B64",
 "includeRawPaths":false,"variantsLimit":20,
 "teoInput":{"materialId":"paper-sa-80","machineId":"flexo-300"}}
JSON
```

### 4.2 Выход

Ответ — конверт с `project_state.json v2` внутри (полный пример:
[`test/examples/response_minimal.json`](test/examples/response_minimal.json),
[`test/examples/response_full.json`](test/examples/response_full.json)):

```jsonc
{
  "schemaVersion": 2,
  "stages": ["calc", "teo"],              // что просил клиент
  "stageResults": {                       // компактные отчёты по стадиям
    "calc": {"rows": 9, "cols": 5, "count": 5040, "revs": 112, "length": 34137.6,
             "wastePct": 26.18, "perLabelArea": 2032.0, "...": "полный MaterialResult"},
    "teo":  {"calc": {…}, "consumption": {…}, "shape": {…}, "teo": {…}, "comparison": {…}}
  },
  "state": {                              // канонический project_state.json v2
    "schemaVersion": 2, "name": "…", "inputFile": "…",
    "params": {…}, "rawPaths": [], "healedPaths": [], "issues": [],
    "pattern": null, "arrayPaths": [], "calc": {…}, "variants": [ {…компактный вид…} ],
    "selectedVariantIndex": 0
  },
  "consumption": {"areaMm2": 10241280.0, "wastePct": 26.1811…, "perLabelMm2": 2032.0, "webMin": 262.0},
  "shape": {"kind": "rect", "w": 50.0, "h": 30.0, "area": 1500.0, "efficiency": 1.0},
  "teo": {"costPer1000": 704.88, "totalCost": 3552.58, "machineCost": 2528.45,
          "materialCost": 1024.13, "runTimeHours": 0.0057, "shiftLoadPct": 6.3212, "…": "…"},
  "teoInput": {…}, "teoComparison": {"bestIndex": 0, "bestCostPer1000": 704.88,
                 "baseCostPer1000": 704.88, "savingsPer1000": 0.0, "compared": 10, "bestTeo": {…}},
  "priceCatalog": {…}, "manufacturingParams": {…}, "variantResults": [ {…полный MaterialResult…} ],
  "metrics": {
    "workerVersion": "0.1.0", "requestedStages": ["calc","teo"],
    "executedStages": ["calc","teo"], "totalMs": 14, "stagesMs": {"calc": 2, "teo": 6},
    "counting": {"rows": 9, "cols": 5, "count": 5040, "revs": 112, "lengthMm": 34137.6,
                 "wastePct": 26.18, "perLabelAreaMm2": 2032.0, "variants": 10},
    "reference": {"checked": true, "passed": true, "expected": {…}, "actual": {…}, "delta": {…}}
  }
}
```

Соответствие схеме UI (`app/lib/src/projects/project.dart`) — 1:1:
`camPathToJson`, `layoutParamsToJson`, `issueToJson`, `patternResultToJson`,
`materialResultToJson`. Два осознанных отличия:

1. `state.calc` отдаётся **полным** `MaterialResult`; массив `state.variants` —
   в сокращённом виде, как в `Project.toJson()` приложения (там варианты
   пишутся укороченным набором полей). Полные значения каждого варианта
   доступны в `variantResults`, чтобы `perLabelArea`/`gapX` не терялись.
2. `updatedAt` в канонический JSON не пишется (домен детерминирован, иначе
   одинаковый вход давал бы разный выход); таймстемп подставляет `api` при
   сохранении `state_json` в БД.

### 4.3 Стадии по отдельности

```
POST /parse     → {"paths": 3}
POST /heal      → {"pathsBefore": 3, "paths": 2, "closed": 2}
POST /analyze   → {"ok": true, "verdict": "Внимание (1 предупреждений)", "counts": {…}, "issuesCount": 1}
POST /pattern   → {"isArray": true, "grid": {"rows": …, "cols": …, "stepX": …, "stepY": …, "arrayPaths": …}}
POST /calc      → полный MaterialResult (9×5, N=5040, 34137.6 мм, 26.18 %, 2032.0 мм²)
POST /variants  → {"count": 20, "limit": 20}
POST /teo       → {"calc": …, "consumption": …, "shape": …, "teo": …, "comparison": …}
```

Стадия сама подтягивает зависимости: `pattern` требует геометрию, `calc`/`variants`/`teo`
считаются и без файла (только по параметрам), а если макет передан — он
разбирается, чтобы `state.rawPaths` был заполнен.

---

## 5. Эталонные числа (N-1, PRD §10.2)

Сверка выполняется автоматически и видна в каждом ответе в
`metrics.reference` (`checked`, `passed`, `expected`, `actual`, `delta`, `eps=0.005`),
а также скриптом:

```bash
cd services/domain-worker
dart tool/verify_reference.dart --http     # домен + живой HTTP на свободном порту
```

Факт (Dart 3.3.4, macOS arm64):

```
  OK   отходы, %: 26.18 (эталон 26.18)
  OK   мм²/этикетку: 2032.0 (эталон 2032.0)
  OK   длина, мм: 34137.6 (эталон 34137.6)
  OK   раппорт, мм: 304.8 (эталон 304.8)
  OK   N (всего этикеток): 5040 / оборотов: 112
  OK   costPer1000, ₽: 704.88      OK  totalCost, ₽: 3552.58
  OK   machineCost, ₽: 2528.45     OK  materialCost, ₽: 1024.13
ЭТАЛОН СОШЁЛСЯ 1:1 (26.18 % / 2032.0 мм² / 704.88 ₽)
```

`delta` по всем восьми числам — `0.0` (совпадение не «в пределах эпсилона», а
бит-в-бит с эталоном `packages/core/tool/e2e.dart`).

---

## 6. Тесты и проверки

`dart test` из pub.dev недоступен — каждый файл в `test/` это обычный скрипт с
`void main()` (конвенция `packages/core`), код выхода 0 = успех.

```bash
cd services/domain-worker
dart pub get --offline
dart analyze                                     # No issues found!
dart test/pipeline_test.dart                     # эталон, стадии, детерминизм, ошибки
dart test/materials_test.dart                    # сериализация v2, ТЭО-секции
dart test/server_test.dart                       # HTTP, коды, изоляты, токен
dart tool/verify_reference.dart --http           # эталон локально и по HTTP
dart tool/make_examples.dart                     # перегенерировать test/examples/*
# всё сразу (как в CI):
bash ../../scripts/run_domain_worker_tests.sh
```

Что проверено фактически (прогон на этой машине):

| Проверка | Результат |
|---|---|
| `dart analyze` | `No issues found!` (lib + bin + test + tool) |
| `test/pipeline_test.dart` | `ALL PASS: pipeline_test` (7 проверок) |
| `test/materials_test.dart` | `ALL PASS: materials_test` (5 проверок) |
| `test/server_test.dart` | `ALL PASS: server_test` (7 проверок, включая 4 параллельных расчёта в изолятах) |
| Полный путь по `quadroring.dxf` | 3 контура → лечение 2 → раскрой/ТЭО; ~117 мс |
| Полный путь по `quadroring.ai` (3 МБ, HTTP + base64) | 4 МБ тела запроса → 200 за **1.12 с** (внутри изолята 75 мс + перенос base64) |
| `/healthz` во время расчёта | 0.8–2 мс (главный поток не блокируется) |
| Graceful shutdown | `SIGTERM` → «останавливаемся…», процесс завершён, код 0 |
| Эталон | совпадение 1:1, `delta = 0.0` |

Ручная проверка живого сервера:

```bash
cd services/domain-worker && dart run bin/domain_worker.dart &
curl -s localhost:8101/healthz
curl -s localhost:8101/status        # requests/errors, active/queued изоляты

---

## 7. Docker и compose

```bash
# из корня репозитория
docker build -f Dockerfile.domain-worker -t pp-domain-worker:latest .
```

Dockerfile: `dart:stable` (образ Dart SDK; сторонние пакеты не ставятся) →
копирование `packages/core` и `services/domain-worker` → `dart pub get --offline`
→ `dart compile exe bin/domain_worker.dart` → рантайм-стадия на `debian:stable-slim`
с curl для healthcheck. Сервис слушает `8101` внутри сети compose; наружу порт
не публикуется (ADR-6) — вызывает только `api` через `DOMAIN_WORKER_URL`.

В `deploy/docker-compose.yml` уже описаны сервис `domain-worker`
(`build.context: ../`, `dockerfile: Dockerfile.domain-worker`), переменные
`PP_CORE_PATH/PP_DATA_DIR`, том `../packages/core:/workspace/packages/core:ro`
и healthcheck `curl -f http://localhost:8101/healthz` — этот Dockerfile
реализует тот контракт.

---

## 8. Границы и ограничения (риски)

- **Воркер не ходит в объектное хранилище.** `storage_key` принимается как
  метаданные, но байты должен прислать `api` (`file_base64`) или смонтированный
  файл (`file_path`). Так у домена нет ни S3-клиента, ни сетевых зависимостей,
  а presigned-ссылки и ACL остаются в одном месте (ADR-5, N-4).
- **base64 и память.** Байты передаются в изолят сообщением: кодирование в
  base64 делает `api`, декодирование — изолят. Для лимита 50 МБ (`PP_MAX_MB`)
  это ≈67 МБ base64 и две копии байтов — приемлемо, но не бесплатно; лимит
  тела `PP_DOMAIN_MAX_BODY_MB=96` защищает от OOM, а для очень больших файлов
  используйте `file_path` (общий том) вместо base64.
- **Изолят на задачу.** Каждая задача порождает изолят (`Isolate.spawn`) и
  убивает его после ответа: нет общего изменяемого состояния → результаты
  детерминированы и не «протекают» между запросами. Цена — ~10–20 мс на старт
  изолята (на фоне ~100 мс расчёта это < 20 %) и отсутствие кэша между
  запросами; параллелизм ограничен `PP_DOMAIN_CONCURRENCY`.
- **Главный поток** делает только HTTP-разбор, `base64Decode` и отправку
  сообщения; тяжёлые `heal/pattern/calc/teo` идут в изоляте. Долгая сериализация
  карты результата также происходит в изоляте, но копирование сообщения в
  главный изолят — операция O(размера ответа): при `includeErrors: true` и
  больших файлах ответ может быть мегабайтным, поэтому по умолчанию тяжёлые
  детали не дублируются.
- **Отчёты (PDF/XLSX/DXF) не реализованы** — это следующая задача (System
  Design §12.8). `packages/core` их умеет (`buildTeoReportPdf`, `buildTeoXlsx`,
  `buildDxfText`), эндпоинты появятся отдельно; кириллица в PDF потребует
  TTF-шрифта в образе (F-18).
- **`analyze` считается по вылеченной геометрии** (как в UI: пользователь
  видит проблемы того набора, с которым дальше работает раскрой).
  `packages/core/tool/e2e.dart` анализирует исходную геометрию — порядок
  вызовов там другой, но математика эталона от этого не зависит (26.18 % /
  2032.0 мм² / 704.88 ₽ — только от параметров раскроя и каталога).
- **Сокращённый вид `state.variants`** сохранён ради совместимости со схемой
  приложения. Если `flutter-web-adapt` начнёт применять вариант из
  `project_state.json`, в приложении нужно расширить `materialResultToJson`
  (сейчас оно теряет `perLabelArea`/`gapX` при сохранении варианта) — со
  стороны воркера полные значения уже отдаются в `variantResults`.
- **Нет доступа к pub.dev** — новых зависимостей добавлять нельзя; всё
  реализовано на `dart:io`, `dart:convert`, `dart:isolate`, `dart:typed_data`.
- Греп-контроль домена (`mask`, `gcode`, «уф-маска», «г-код») остаётся
  обязательным: воркер ничего такого не добавляет и `packages/core` не меняет.
