# 02. Форматы и схемы данных «Препресс-Планер»

**Статус: актуален на 2026-09-07 (HEAD bed533e)**

> Ветка `master`, коммит `bed533eb698b333ae2cd067be5d5ff91261db0e5`.
> Поля и типы сверены чтением кода; ссылки — `путь/файл:строка`.
> Полные HTTP-payload'ы — `04_services_api.md`; здесь только выжимка (§9).

## 1. Где какие данные лежат

Каталоги приложения: проекты — `'projects'` (`app/lib/main.dart:60`), состояние —
`'state'` (`app/lib/main.dart:36,39,41`). Хранилище абстрагировано `JsonStore`
(`app/lib/platform/json_store.dart:14-26`): desktop — файлы, каталог создаётся
рекурсивно (`json_store_io.dart:16-20`); web — localStorage с префиксом
`pp_prepress_planner.`, где `''`/`'.'` → `root` (`json_store_web.dart:10-20`).

| Данные | Формат | desktop | web |
|---|---|---|---|
| Проект | JSON, `schemaVersion: 2` | `<проекты>/<имя>.json` | `projects/<имя>.json` |
| Материалы пользователя | JSON, `version: 1` | `state/materials.json` | `state/materials.json` |
| Сессия аккаунта | JSON | `state/session.json` | `state/session.json` |
| Энтайтлмент | JSON | `state/entitlement.json` | `state/entitlement.json` |
| ID устройства | plain text (UUID) | `state/machine_id.txt` | `state/machine_id.txt` |
| Отчёты | PDF / XLSX / DXF | каталог проектов (§8) | скачивание браузером |
| Данные сервисов | SQLite / JSON-задачи | `PP_DATA_DIR` сервиса | — |

Файла каталога цен **в коде не найдено** — всегда `PriceCatalog.defaults()` (§6.1).

## 2. Состояние проекта — JSON v2

Схема — `app/lib/src/projects/project.dart`. Комментарий модуля называет файл
`project_state.json v2` (`:1`); фактическое имя — по имени проекта (§3).

### 2.1. Корень (`Project.toJson()`, `:102-116`)

| Поле (тип) | Запись / чтение (дефолт) | Смысл |
|---|---|---|
| `schemaVersion` (`int` = **2**) · `name` (`String`) | `:103` · `:104` / `:128` (`'Проект'`) | версия схемы (при чтении не проверяется) · имя проекта |
| `inputFile` (`String`) · `params` (`Object`) | `:105` / `:129` (`''`) · `:106` / `:130-131` | исходный файл задания · параметры раскроя (§2.2) |
| `rawPaths` (`Array`) · `healedPaths` (`Array`) | `:107` / `:132-135` · `:108` / `:136-139` | исходная геометрия (§2.3) · вылеченная (слои `HEALED_*` / `MASTER`) |
| `issues` (`Array`) · `pattern` (`Object\|null`) | `:109` / `:140-143` · `:110` / `:144-145` | проблемы (§2.4) · распознанный массив (§2.5) |
| `arrayPaths` (`Array`) · `calc` (`Object\|null`) | `:111` / `:146-149` · `:112` / `:119-126` | сетка копий (слой `ARRAY`) · выбранный вариант (§2.6) |
| `variants` (`Array`) · `selectedVariantIndex` (`int`) | `:113` / `:120-123` · `:114` / `:152` (`0`) | все варианты (§2.6) · индекс выбранного |
| `updatedAt` (`String` ISO-8601) | `:115` / `:153-154` (`now`) | время изменения |

Чтение устойчиво к отсутствию любого поля (`:118-156`). Обратная совместимость
с v1 **в коде не найдена**: `fromJson` поле `schemaVersion` не читает.

### 2.2. `params` (`:31-63`)

Запись — `layoutParamsToJson` (`:31-46`), чтение — `layoutParamsFromJson`
(`:48-63`); дефолты совпадают с `LayoutParams`
(`packages/core/lib/src/model/params.dart:18-33`). `mode` ∈ `'count' | 'length'`;
`rapportManual > 0` → ручной раппорт вместо `Z·CP`.

| Ключ | Дефолт | Ключ | Дефолт | Ключ | Дефолт |
|---|---|---|---|---|---|
| `labelW` `double` | `50` | `gapY` `double` | `3` | `cylWidth` `double` | `300` |
| `labelH` `double` | `30` | `zTeeth` `int` | `96` | `webWidth` `double` | `300` |
| `gapX` `double` | `3` | `cp` `double` | `3.175` | `undercut` `double` | `0.48` |
| `minGap` `double` | `3` | `rapportManual` `double` | `0` | `mode` `String` | `'count'` |
| `count` `int` | `5000` | `length` `double` | `10000` | | |

### 2.3. `CamPath` (`:11-28`)

`{"points": [[x, y], …], "closed": bool, "layer": String}` — точки в мм, Y вверх
(`:12-14`); при чтении `closed` строго `== true` (`:26`), `layer` при отсутствии —
`''` (`:27`). Слои: `HEALED_POLY`, `HEALED_HOLE`, `HEALED_TAIL`
(`packages/core/lib/src/healer/morphology.dart:6-7`), `MASTER`
(`app/lib/src/screens/geometry_screen.dart:879,985`), `ARRAY`
(`packages/core/lib/src/optimizer/array_generator.dart:12`).

### 2.4. `Issue` (`:159-183`)

| Ключ (тип) | Дефолт | Ключ (тип) | Дефолт |
|---|---|---|---|
| `kind` (`String`) | `''` `:160` | `message`, `suggestion` (`String`) | `''` `:165-166` |
| `severity` (`String`) | `'warning'` `:161` | `fixable` (`bool`) | `false` `:167` |
| `points` (`Array<[double,double]>`) | `[]` `:162-164` | `index` (`int`) | `0` `:168` |

Допустимые `kind`/`severity` — `packages/core/lib/src/model/issue.dart:5-6`.

### 2.5. `pattern` (`:185-228`)

Мастер-элемент и закон сохраняются полностью (`:187-189`).

| Ключ | Дефолт | Ключ | Дефолт | Ключ | Дефолт |
|---|---|---|---|---|---|
| `isArray` `bool` | `false` | `rows`, `cols` `int` | `0` | `count` `int` | `0` |
| `masterPaths` | `[]` | `stepX`, `stepY` `double` | `0` | `labelW`, `labelH` | `0` |
| `offsets` | `[]` | `gapX`, `gapY` `double` | `0` | `masterArea` `double` | `0` |

При `isArray: false` `masterPaths` = сам контур, `rows = cols = count = 1`, шаги и
зазоры = 0 (`packages/core/lib/src/optimizer/pattern_recognition.dart:26-28`);
`pattern: null` → `null` (`:204-205`).

### 2.6. `calc` / `variants` (`:230-289`)

Запись — `materialResultToJson` (`:230-257`), чтение — `materialResultFromJson`
(`:259-289`): **при `error != null`** возвращается `MaterialResult.withError(error)`,
остальные поля игнорируются (`:260-261`).

| Ключи (все — с дефолтом `0`/`false`, кроме `error`) | Типы |
|---|---|
| `labelW`, `labelH`, `stepX`, `stepY`, `gapYActual`, `usedWidth`, `webMin` | `double` |
| `rapport`, `dPitch`, `dCyl`, `length`, `webWidth`, `areaMm2`, `areaM2` | `double` |
| `usedAreaMm2`, `wastePct`, `perLabelArea` | `double` |
| `rows`, `cols`, `perRev`, `revs`, `count`, `excessLabels` | `int` |
| `error` (`String\|null`, без дефолта), `mode` (`String`, дефолт `'count'`), `rotated` (`bool`, `false`) | — |

> **Внимание.** `gapX`, `gapYRequested`, `countRequested` есть в `MaterialResult`
> (`packages/core/lib/src/calculator/material.dart:107-110`) и попадают в PDF-отчёт,
> но **в JSON проекта не сохраняются** (`project.dart:230-257`); после перезагрузки
> зазоры берутся из `params`.

## 3. Именование файлов проекта

| Правило | Реализация |
|---|---|
| Имя файла | `'${_sanitize(name)}.json'` — `project.dart:303` |
| Санитизация | всё, кроме `\w`, `-`, пробела и `U+0400…U+04FF`, → `_`, затем `trim()` — `:300-301` |
| Список / чтение | имена `*.json` каталога без расширения (`json_store_io.dart:34-46`); `load` → `jsonDecode` → `Project.fromJson` (`project.dart:309-314`). Проекты, различающиеся только спецсимволами, могут **перезаписать** друг друга — уникального id в коде не найдено |

## 4. `session.json` — сессия аккаунта

Поля — `{"token": String, "email": String}` (`app/lib/license/account_client.dart:33`).
Запись — `SessionStore.save` (`:91-93`); чтение — `load` (`:95-105`): при пустом
`token` или ошибке разбора → `null` (`:101-104`); удаление — `clear` (`:107-109`).
Каталог — `stateDir` (`app/lib/main.dart:39`; `license_controller.dart:23,38`).
Токен — opaque (`secrets.token_urlsafe(32)`, `services/auth/auth_app/main.py:132-133`),
в БД только `sha256` (`:128-148`); на клиенте хранится открытым текстом (`SECURITY.md:28`).

## 5. `entitlement.json` и `machine_id.txt`

`entitlement.json`: схема — `Entitlement.toJson`
(`app/lib/license/license_client.dart:23-28`), чтение — `fromJson` (`:30-37`),
хранилище — `EntitlementStore` (`app/lib/license/entitlement_store.dart:11-37`).

| Поле | Тип | Дефолт | Смысл |
|---|---|---|---|
| `pro` | `bool` | `false` (строго `== true`) | Pro активна |
| `until` | `String` ISO-8601 \| `null` | `null` | срок действия |
| `trialDaysLeft` | `int` | `0` | остаток триала |
| `source` | `String` | `'local'` | `'server'` \| `'cache'` \| `'local'` (`:15`) |

Офлайн-грэйс — **30 дней** от даты в кэше (`entitlement_store.dart:30-36`).
`FeatureGate` (`:40-68`): `hasProAccess = isPro || isTrialActive`; во Free разрешены
только `project.create` и `layout.rect` (`:57-67`). Триал — **15 дней**
(`license_client.dart:69-76`). `machine_id.txt` — **не JSON**: plain text,
UUID-подобная строка; создаётся при первом обращении, читается с `trim()`
(`:105-114`). Генератор — собственный LCG `_Random` (`:129-135`) → находка
`SECURITY.md:37` («`machine_id` на слабом ГПСЧ»).

## 6. Каталог цен (`PriceCatalog`) и `materials.json`

### 6.1. `PriceCatalog` — JSON-схема

`packages/core/lib/src/economics/price_catalog.dart`; имена полей английские,
nullable-поля при `null` в JSON **отсутствуют** (`:5-6`).

| Ключ | Тип и дефолты | Строка |
|---|---|---|
| `currency` | `String`, `'₽'` | `:28,106` |
| `workTime` | `{hoursPerShift: double, shiftsPerDay: int}`, `8.0` / `1` | `:29-32,98-99` |
| `assortment` | `Array`; элемент — `id`, `name` (`''`), `pricePerM2` (`0.0`), `minOrderM2` **опционален** | `:33-41,39,69` |
| `machines` | `Array`; элемент — `id`, `name` (`''`), `ratePerHour` (`0.0`), `speedMetersPerMin` **опц.**, `labelsPerHour` **опц.** (`toInt()` при чтении), `setupTimeHours` (`0.0`), `setupMaterialMeters` (`0.0`) | `:42-54,48-50,84-88` |

**Образец** `PriceCatalog.defaults()` (`:110-149`); «(пример)» — часть строки `name`
(`:111`), цены демонстрационные:

| `id` | Что | Цена | Скорость | Прочее |
|---|---|---|---|---|
| `paper-sa-80` | Бумага самоклеящаяся 80 г/м² | 100.0 ₽/м² | — | `minOrderM2: 500.0` |
| `film-pet-50` | Плёнка ПЭТ 50 мкм | 250.0 ₽/м² | — | `minOrderM2: 300.0` |
| `film-pp-40` | Плёнка ПП 40 мкм | 180.0 ₽/м² | — | `minOrderM2: 300.0` |
| `flexo-300` | Флексопечать, ширина 300 мм | 5000.0 ₽/ч | `speedMetersPerMin: 100.0` | `setupTimeHours: 0.5` |
| `digital-label` | Цифровая печать этикеток | 9000.0 ₽/ч | `labelsPerHour: 2500` | `setupTimeHours: 0.1` |

`fromJson`/`toJson` в UI не вызываются (`reports_screen.dart:36,46,65-66`).

### 6.2. `materials.json` — библиотека пользователя

`app/lib/src/materials/material_library.dart`, файл в каталоге `state` (`:23`;
`app/lib/main.dart:41`). Схема (`_save`, `:162-179`):

| Поле | Тип | Строка | Смысл |
|---|---|---|---|
| `version` | `int` = **1** | `:166` | версия схемы (при чтении не проверяется) |
| `selected` | `String\|null` | `:167` | `id` выбранного; `null` — по умолчанию |
| `items` | `Array` | `:168-176` | только **пользовательские** материалы |

Элемент `items` (`:170-175`): `id`, `name` — обязательные непустые строки;
`pricePerM2` пишется всегда (при чтении `0.0`); `minOrderM2` — **опционален**, при
`null` в JSON отсутствует (`:174`). Встроенный каталог-пример в файл **не
попадает**, список для UI — `defaults + customs` (`:31-39`); `id` нового материала
— `m-<microsecondsSinceEpoch в base36>` (`:91-92`); добавление требует непустого
имени и `pricePerM2 > 0` (`:89-90`), `minOrderM2 <= 0` → «нет ограничения»
(`:97-99`); элементы без непустых `id`/`name` при чтении пропускаются (`:149-151`),
ошибка чтения не роняет приложение (`:74-75`), запись — с отступом 2 пробела (`:165`).

## 7. Форматы импорта и что с ними происходит

Диспетчер — `parseBytes(bytes, name)` по расширению
(`packages/core/lib/src/parser/parse_file.dart:23-47`).

| Формат | Локально | Поведение |
|---|---|---|
| DXF | да | единицы `$INSUNITS` (дефолт 4 = мм; 1 → ×25.4, 5 → ×10, 6 → ×1000); `LINE`, `LWPOLYLINE` (bulge), `POLYLINE`+`VERTEX`, `CIRCLE`, `ARC`, `SPLINE` (Cox-de Boor), `ELLIPSE`; дуги — хорда ~0.05 мм, сплайны ~0.05 мм (лимит 20000 точек) (`dxf_parser.dart:1-7,43-63`) |
| SVG | да | 25.4/96 мм/ед либо `width_mm/viewBox`; Y инвертируется; слой `'SVG_VECTOR'` (`svg_parser.dart:1-6,18`) |
| PDF | да | объекты/xref, `/FlateDecode`, `/Contents`, `/MediaBox` через `/Parent`; операторы `q/Q/cm/m/l/c/v/y/re/h/S/s/f/F/B/b/n/W`; текст и изображения пропускаются; pt→мм 25.4/72; слой `'PDF_VECTOR'` (`pdf_parser.dart:1-7,20`) |
| AI | условно | начинается с `%PDF-` → как PDF; иначе `ParserException` → серверная конвертация (`parse_file.dart:34-36,50-53`) |
| CDR / EPS / прочее | нет | `ParserException('Формат CDR\|EPS\|<FMT>: требуется серверная конвертация.')`; `<FMT>` — расширение в верхнем регистре (`:37-46`) |

**Сервис конвертации.** Клиент отправляет байты полем `file` с именем `import<ext>`
(`app/lib/src/converter/converter_api.dart:120-127`), опрашивает статус и скачивает
результат (`:142-200`); всегда просит `target=svg` (`:126`). Маршрутизация
(`services/converter/converter_app/convert.py:137-204`): `.ai` PDF-совместимый +
`target=pdf` → копия файла (`:152-157`); тот же AI + `target=svg` → Inkscape
`--export-text-to-path` (`:158-169`); `.ai` без PDF-совместимости → каскад Inkscape
с понятной ошибкой (`:171-184`); `.cdr` → Inkscape (`:186-198`); `.eps` → Ghostscript
→ PDF (`:200-204`). Движки: `PP_INKSCAPE` → `cam_pipeline` → `PATH` (`:35-57`),
`PP_GHOSTSCRIPT` → `PATH` (`:59-105`). Ограничения: расширения `{.ai, .cdr, .eps}`
(`main.py:102-107`), размер ≤ `PP_MAX_MB` (дефолт 50, `:37,114-119`), `job_id` =
`uuid4().hex[:12]` (`jobs.py:78,158`). Фикстуры: `fixtures/quadroring.{dxf,svg,pdf,ai,cdr,eps}`,
`petlya.*`, `zvezda.{eps,pdf}`, `petlya_open_artifacts.*`, `v205_150x100_paper.ai`;
`samples/label_grid_5x6.{svg,eps}`.

## 8. Форматы экспорта и точные имена файлов

Имена заданы строковыми константами в `app/lib/src/screens/reports_screen.dart`:

| Кнопка | Имя файла | Формат | Строка |
|---|---|---|---|
| «PDF ТЭО» | `04_ТЭО_Отчёт.pdf` | PDF 1.4, A4, внедрённый TTF | `:196,199,201` |
| «XLSX» | `05_Расчёт.xlsx` | XLSX (ZIP+XML) | `:220,223,225` |
| «DXF мастера» | `02_Вылеченный_Мастер.dxf` | DXF R2000 (AC1015) | `:242-244` |
| «DXF мастера» (если массив непуст) | `03_Раскрой.dxf` | DXF R2000 (AC1015) | `:245-250` |

DXF выгружаются одним нажатием: сначала мастер, затем сетка (`:241-250`).

| Платформа | Куда сохраняется | Строка |
|---|---|---|
| desktop | каталог `store.directory` = `'projects'` (≈ `app/projects/`), рядом с JSON проектов | `reports_screen.dart:109-110`; `save_out_io.dart:7-16` |
| web | каталог игнорируется, файл скачивается браузером | `save_out_web.dart:8-9`; `save_out.dart:1-3` |

| Формат | Содержимое | Строка |
|---|---|---|
| PDF | «ТЭО РАСЧЁТА РАСКРОЯ»: проект и файл; этикетка и зазоры; шестерня и раппорт; цилиндр/полотно; раскладка, обороты, тираж, длина, площади; машиночасы и загрузка смены; сортамент, материал, смены, оснастка, наценка; себестоимость 1000 шт и этикетки; сравнение вариантов; подвал «Препресс-Планер · стр. N» | `reports/teo_report.dart:162-261,274` |
| XLSX | листы «Расчёт», «ТЭО», «Варианты» | `reports/teo_xlsx.dart:38-40` |
| DXF | HEADER (`$ACADVER`, `$INSUNITS=4`), TABLES (слои), ENTITIES (`LWPOLYLINE`: 90 — вершин, 70 — замкнутость, 10/20 — координаты); 4 знака; не-ASCII слои как `\U+XXXX`; пути < 2 точек пропускаются | `reports/dxf_writer.dart:29-84,70` |

Пути `reports/*` — внутри `packages/core/lib/src/`. Шрифт PDF —
`assets/fonts/DejaVuSans.ttf` через `rootBundle` (`reports_screen.dart:122-133`;
`app/pubspec.yaml:27-28`); на desktop фасад ищет системный TTF
(`packages/core/lib/io.dart:76-128`). Эталоны — `test/golden/`: `report_teo.pdf`,
`report_teo.xlsx`, `paths_roundtrip.dxf`, `report_teo_real.{pdf,xlsx}`,
`label_contour_real.dxf` (`packages/core/test/reports_test.dart:104,148,199,283-285`).

## 9. API-payload'ы (выжимка)

| Сервис | Метод и путь | Запрос → ответ |
|---|---|---|
| converter :8120 | `POST /convert` | multipart `file` (.ai/.cdr/.eps) + `target` = `svg\|pdf` → `{"job_id"}` (`main.py:92-124`) |
| converter | `GET /convert/{job_id}` | → `{"status": "pending\|running\|done\|error", "result_url"?, "error"?}` (`:127-139`) |
| converter | `GET /healthz` | → `{"status","engines":{"inkscape","ghostscript"},"job_store"}` (`:79-89`) |
| auth :8121 | `POST /auth/register`, `/auth/login` | `{email, password, device_id}` → `{token, user}` (`:239-248,299-329`) |
| auth | `POST /auth/verify` | `Authorization: Bearer` → claims (`sub`, `email`, `device_id`) (`:369-379`) |
| auth | `POST /auth/forgot`, `/auth/reset` | `{email}` → `{ok, dev_code?, dev_hint?}` — **К-1**; `{email, code, new_password}` (`:381-428`) |
| auth | `GET /auth/me`, `/auth/devices`, `/healthz` | `Authorization: Bearer` (`:343,348,430`) |
| payments :8122 | `GET /payments/plans`, `POST /payments/checkout` | тарифы; `{plan}` → `{order_id, plan, title, amount_rub, status:"pending", url, hint}` (`:247-251,146-164`) |
| payments | `POST /payments/orders/{id}/confirm`, `GET /payments/subscription`, `POST /payments/webhook` | подписка (заглушка, **К-4**); `{plan, pro, until}`; вебхук-заглушка (`:167-189,238-243,204-236`) |
| license | `POST /license/activate`, `/license/validate`, `GET /license/entitlements/{id}`, `/admin/keys`, `/webhooks/*` | сервис **не в прод-стеке** (`license_app/main.py:52,60,67,72,81,88,95`) |

Ограничения полей auth: `email` 3–254, `password` 6–128 (в `login` 1–128),
`device_id` 1–128 (`:239-259`). TTL сессии — **720 ч** (`PP_TOKEN_TTL`, `:55`),
TTL кода сброса — **30 мин** (`PP_RESET_TTL`, `:57`), лимит устройств **1/1** (`:6`).
Тарифы — `PLANS` (`payments main.py:48-50`): `month` 990 ₽ / 30 дн., `year` 9900 ₽ /
365 дн.; продление — от конца активной подписки (`:184-189`). Ошибки — FastAPI-стиль
`{"detail": …}`; клиент разбирает и строку, и список (`converter_api.dart:210-224`).

## 10. Офлайн-токен лицензии

`services/license/license_app/crypto.py`:

| Свойство | Значение | Строка |
|---|---|---|
| Формат | `base64url(payload) + "." + base64url(signature)` | `:10-11,42` |
| Кодирование | base64url без `=`, декодирование с восстановлением паддинга | `:21-27` |
| `payload` | JSON `{machine_id, until, tier, iat}` (порядок полей важен) | `:36-37` |
| Компактность | `separators=(",", ":")`, `ensure_ascii=False`; время — naive UTC ISO | `:32,38` |
| Подпись / проверка | **HMAC-SHA256** по ASCII-строке `body` (не по сырому payload); `hmac.compare_digest` | `:40-42,50-52` |
| Сроки | `until < now` → недействителен; выдан > 30 дней назад → недействителен; `GRACE_DAYS = 30` | `:13,58-61` |
| Ключи активации | `XXXX-XXXX-XXXX-XXXX`, алфавит без похожих символов | `:67-74` |
| Хеш machine-id | `sha256(machine_id)[:24]` — сырой id в ключах не хранится | `:16-18` |

> **⚠️ Предупреждение о дефолтном секрете.** `signing_secret()` берёт
> `PP_LICENSE_SECRET`, а при его отсутствии возвращает **публичную константу
> `"dev-secret-change-me"`** (`crypto.py:77-79`). С этим секретом подпись
> офлайн-токена может сгенерировать кто угодно — режим пригоден только для
> разработки. Факт зафиксирован в `SECURITY.md:38`; исправления отложены заказчиком.

## 11. Правила совместимости

| Правило | Как обеспечено |
|---|---|
| **Аддитивные изменения** | у каждого поля есть дефолт при чтении (`project.dart:128-154`; `price_catalog.dart:66-99`; `material_library.dart:147-157`) — новый **необязательный** ключ не ломает старые записи |
| **Версия схемы проекта** | пишется `schemaVersion: 2` (`project.dart:103`), при чтении **не проверяется** (`:118-156`) → несовместимость не диагностируется |
| **Версия `materials.json`** | пишется `version: 1` (`material_library.dart:166`), при чтении **не проверяется** (`:57-80`) |
| **Отсутствие null-полей** | nullable-поля не пишутся вовсе: `minOrderM2` (`price_catalog.dart:39`; `material_library.dart:174`), `speedMetersPerMin`, `labelsPerHour` (`price_catalog.dart:48-50`) |
| **Ошибка — поле, не исключение** | `MaterialResult.error` / `TeoResult.error`; при `error != null` числовые поля нулевые (`project.dart:260-261`; `material.dart:149`; `teo.dart:105`) |
| **Переименование поля — ломающее** | алиасов в `fromJson` нет: старый ключ молча игнорируется, поле получает дефолт |
| **Удаление поля** | чтение безопасно, запись — нет: старая сборка перезапишет файл без нового поля |
| **Формат офлайн-токена** | изменение набора или порядка полей `{machine_id, until, tier, iat}` делает ранее выданные токены невалидными: подпись считается по base64-строке `body` (`crypto.py:30-42`) |

### 11.1. Найденные слабые места

| # | Что | Где |
|---|---|---|
| 1 | `schemaVersion` не проверяется при чтении — несовместимый файл читается с дефолтами вместо ошибки | `project.dart:118` |
| 2 | Запись проекта безусловная — незнакомая версия будет перезаписана | `project.dart:305-307` |
| 3 | Отчёты пишутся в каталог проектов, смешиваясь с JSON проектов | `reports_screen.dart:109-110` |
| 4 | `gapX`, `gapYRequested`, `countRequested` не сохраняются → отчёт после перезагрузки может расходиться с исходным (§2.6) | `project.dart:230-257` |
| 5 | Имена проектов санитизируются необратимо — возможна перезапись (§3) | `project.dart:300-303` |

## 12. Связанные документы

`00_architecture.md` · `01_domain_core.md` · `03_app_ui.md` ·
**`04_services_api.md` — полный HTTP-контракт сервисов** · `05_platforms_builds.md` ·
`06_deploy_ops.md` (развёртывание, `PP_*`) · `08_security.md` · `SECURITY.md`
(аудит К-1…К-5) · `docs/VERIFICATION.md` (прогоны).
