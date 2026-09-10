# 01. Домен `packages/core` — модули и API

**Статус: актуален на 2026-09-07 (HEAD bed533e)**

> Ветка `master`, коммит `bed533eb698b333ae2cd067be5d5ff91261db0e5`.
> Сигнатуры сверены чтением кода; ссылки — `путь/файл:строка`.
> Расхождения с историческими контрактами `agents/00..14.md` помечены явно.

---

## 0. Пакет

| Свойство | Факт |
|---|---|
| Язык / зависимости | Чистый Dart, только stdlib: `dependencies: {}`, `dev_dependencies: {}` — `packages/core/pubspec.yaml:10-12` |
| Баррель | `packages/core/lib/prepress_core.dart:8-38` — 30 экспортов |
| `io.dart` **не** в барреле | `dart:io` отсутствует в браузере (`io.dart:1-3`) |
| Тесты | 16 исполняемых скриптов (`void main()`); запуск `dart test/<файл>.dart` из `packages/core`; цикл — `scripts/run_domain_tests.{ps1,sh}` |
| Диагностика | `tool/e2e.dart` (эталон), `tool/profile_heal.dart`, `tool/stat_analyze.dart` |
| Импорт из приложения | `package:prepress_core/prepress_core.dart` (`app/lib/src/projects/project.dart:6`) |

---

## 1. `model/` — базовые типы

| Пункт | Содержание |
|---|---|
| Назначение | Точка, полилиния, параметры, проблема — сквозные типы конвейера |
| API | `Vec2(x, y)` + `+ - *`, `length`, `lengthSquared`, `normalized`, `dot`, `cross`, `round4()` — `vec2.dart:4-24`; `CamPath(points, {isClosed = false, layerName = ''})`, `copyWith`, `lengthMm` — `cam_path.dart:5,10,12,17`; `LayoutParams` (14 полей + `copyWith`) — `params.dart:2,35`; `ManufacturingParams` (4 поля) — `params.dart:70`; `Issue(kind, severity, points, message, suggestion, fixable, index)` — `issue.dart:4-21`; реэкспорт — `model.dart:1-4` |
| Вход → выход | Вход расчёта (`LayoutParams`), анализа (`ManufacturingParams`); выход анализа (`Issue`); транспорт геометрии (`CamPath`) |
| Инварианты | мм и ось Y вверх, кривые дискретизированы (`cam_path.dart:3-4`); дефолты 50×30 / зазоры 3 / Z=96 / CP=3.175 / `undercut` 0.48 / цилиндр и полотно 300 / `minGap` 3 / `count` 5000 (`params.dart:18-33`); `rapportManual > 0` → ручной раппорт (`params.dart:9`); `Vec2.==` — 1e-9 (`vec2.dart:32-36`); `kind` ∈ `open\|intersection\|duplicate\|dust\|sharp_corner\|small_gap`, `severity` ∈ `error\|warning\|suggestion` (`issue.dart:5-6`) |
| Зависимости | только `dart:math` (`vec2.dart:1`) |
| Тесты | отдельного файла нет; участвует транзитивно почти во всех 16 скриптах |
| Подводные камни | замыкающее ребро в `lengthMm` учитывается лишь при `isClosed && points.length > 2` (`cam_path.dart:22`) |

---

## 2. `geom/` — полигоны, предикаты, булевы операции

| Пункт | Содержание |
|---|---|
| Назначение | Тип «полигон», метрики и предикаты, структурные операции: `lineMerge`, `polygonize`, `unaryUnion`, `buffer` |
| API | `BBox` + `empty()`, `isEmpty`, `width`, `height`, `center`, `expand`, `unite`, `containsPoint` — `polygon2.dart:11,17,23,25,27,29,33,40,50`; `Polygon2(rings)` (`rings[0]` — внешнее, далее отверстия), `isEmpty`, `area`, `centroid`, `bounds`, `outerRing` — `:69,74,80,92,111,120`; `ringArea` `:30`, `ringAreaAbs` `:33`, `ringCentroid` `:36`, `ringBounds` `:64`, `pointInRing` `:87`, `ringCoversRing` `:108`, `segmentIntersections` `:141`, `pointSegmentDistance` `:190`, `simplifyRing` `:213`, `camPathToPolygon` `:286`, `normalizeRings` `:292`, `cleanRing` `:319`, `angleAt` `:328` (все — `geom_ops.dart`); `lineMerge` `:21`, `polygonize` `:259`, `nodeLineSegments` `:271`, `unaryUnionPolygons` `:440`, `bufferPolygons(input, distance, {join = 'round', mitreLimit = 5.0})` `:573` (все — `geom_boolean.dart`) |
| Вход → выход | `List<List<Vec2>>` → `List<Polygon2>` (полигонизация); `List<Polygon2>` → `List<Polygon2>` (union, buffer); кольцо → числа/булевы значения |
| Инварианты | ориентация колец произвольна — берётся модуль знаковой площади (`polygon2.dart:66-68`); `area` вычитает модули отверстий и не может быть < 0 (`:79-89`); пустая оболочка `min > max`, без NaN (`:16-21`); явный дубль первой точки допустим (`:3-5`); кольцо трактуется как неявно замкнутое (`geom_ops.dart:4-5`); буфер объединяет результат после офсета (`geom_boolean.dart:599-600`) |
| Зависимости | только `model/` и `dart:math` |
| Тесты | `geom_golden_test.dart` (11 OK), `geom_smoke_test.dart` (1 OK) |
| Производительность | кандидаты на пересечение выбираются bbox-сеткой `_bboxOverlapNeighbors` (`geom_boolean.dart:345`) вместо полного перебора — вызовы в `:174-175` и `:289`. Коммит `2f1513c`: «анализ >90 с → ~0.8 с» на PDF/SVG; результаты побитово те же |
| Подводные камни | `lineMerge` не обрабатывает коллинеарные наложения (`:20`); в лечении он намеренно **не** применяется — срезает замыкающий дубль и «открывает» замкнутые контуры (`healer/morphology.dart:49-54`) |

---

## 3. `parser/` — векторный импорт

| Пункт | Содержание |
|---|---|
| Назначение | Единый вид `List<CamPath>` (мм, Y вверх) из DXF/SVG/PDF/AI |
| API | `abstract BaseParser` → `List<CamPath> parseBytes(Uint8List)` — `base_parser.dart:8`; `ParserException` — `parser_exception.dart:2`; `DxfParser` `dxf_parser.dart:19`, `SvgParser` `svg_parser.dart:20`, `PdfParser` `pdf_parser.dart:22`, `AiPdfParser` `ai_pdf_parser.dart:18`; `InflateException`, `inflateZlib`, `inflate` — `inflate.dart:7,149,172`; `parseBytes(Uint8List, String)`, `isPdfBytes(List<int>)` — `parse_file.dart:23,50` |
| Диспетчер | по расширению имени (`parse_file.dart:23-47`): `.dxf` `:25`, `.svg` `:28`, `.pdf` `:31`, `.ai` `:34`; `.eps`/`.cdr`/прочее → `ParserException('… требуется серверная конвертация.')` `:37-46` |
| Масштаб и дискретизация | DXF — `$INSUNITS` (дефолт 4 = мм; 1 → ×25.4, 5 → ×10, 6 → ×1000), дуги хордой ~0.05 мм, сплайны ~0.05 мм по длине (лимит 20000 точек) — `dxf_parser.dart:3-7,43-63`; SVG — 25.4/96 мм/ед или `width_mm/viewBox`, Y инвертируется, слой `'SVG_VECTOR'` — `svg_parser.dart:3-6,18`; PDF — pt→мм 25.4/72, Y от высоты `/MediaBox`, слой `'PDF_VECTOR'` — `pdf_parser.dart:1-7,20`; AI — как PDF, если начинается с `%PDF-` (`parse_file.dart:34-36,50-53`) |
| Вход → выход | `Uint8List` + имя файла → `List<CamPath>`; ошибка — `ParserException` с русским текстом |
| Инварианты | сущности DXF: `LINE`, `LWPOLYLINE` (bulge), `POLYLINE`+`VERTEX`, `CIRCLE`, `ARC`, `SPLINE` (Cox-de Boor), `ELLIPSE` (`dxf_parser.dart:3-4`); PDF-операторы `q/Q/cm/m/l/c/v/y/re/h/S/s/f/F/B/b/n/W`, текст и изображения пропускаются (`pdf_parser.dart:4-7`); пустой результат SVG/PDF → `ParserException` (`svg_parser.dart:34-36`; `pdf_parser.dart:38-41`) |
| Зависимости | `model/`; `/FlateDecode` — собственный inflate (`inflate.dart:149`) |
| Тесты | `dxf_test` 2, `svg_test` 1, `pdf_test` 1, `inflate_test` 7, `parse_file_test` 7 |
| Подводные камни | `parseBytes` — чистая байтовая функция, ФС только в `io.dart` (`parse_file.dart:8-9`); DXF декодируется UTF-8 с `allowMalformed`, fallback latin1 (`dxf_parser.dart:23-27`) |

---

## 4. `healer/` — лечение геометрии

| Пункт | Содержание |
|---|---|
| Назначение | Предфильтр мусора → снаппинг концов → нодинг+полигонизация → сварка (`buffer ±0.005`, round) → извлечение полигонов/отверстий → остаточные «хвосты» (`morphology.dart:1-8`) |
| API | `MorphologicalHealer({tolerance = 0.01, minLoopArea = 0.0})` `:17,21-22`; `List<CamPath> heal(List<CamPath>)` `:24`; внутренняя `_BoundaryGrid` `:213` |
| Вход → выход | `List<CamPath>` (грязная геометрия) → `List<CamPath>` со слоями `HEALED_POLY`, `HEALED_HOLE`, `HEALED_TAIL` (`:6-7`) |
| Инварианты | полигонизация идёт по снапнутым линиям напрямую, `lineMerge` не применяется (`:49-54`); каждый полигон варится отдельно — совместный `unaryUnion` почти касающихся граней теряет площадь (`:64-74`); объединение кусков принимается только при сохранении площади (`sumAfter >= sumBefore − 0.01`), иначе части остаются раздельными (`:75-85`) |
| Зависимости | `geom/polygon2`, `geom/geom_ops`, `geom/geom_boolean`, `model/*`, `dart:math` (`:10-15`) |
| Тесты | `healer_test.dart` (6 OK) |
| Производительность | `_BoundaryGrid` (`:213-270`) заменяет перебор пар при поиске остаточных линий — часть ускорения коммита `2f1513c` |
| Подводные камни | рабочий `tolerance` приходит из `ManufacturingParams` (= 2.0), а не из дефолта класса 0.01 (`manufacturability/analyzer.dart:85-87`; `model/params.dart:77`) |

---

## 5. `optimizer/` — массивы и топология

| Пункт | Содержание |
|---|---|
| Назначение | Распознать закон Step&Repeat, изолировать мастер, сгенерировать сетку, упростить геометрию |
| API | `PatternResult` (`isArray`, `masterPaths`, `offsets`, `rows`, `cols`, `stepX`, `stepY`, `gapX`, `gapY`, `count`, `labelW`, `labelH`, `masterArea`) — `pattern_recognition.dart:29-49,51-65`; `PatternRecognizer({tolerance = 0.5})` `:76,80`; `analyze(List<CamPath>)` `:83`; `multiplyPaths(master, offsets, {layerName = 'ARRAY'})` `array_generator.dart:11-12`; `autoRowsForRapport(rapport, labelH, minGap)` `:29`; `generateArrayGrid(master, {cols, rows, stepX, stepY, layerName})` `:39-44`; `TopologicalOptimizer({simplifyTolerance = 0.001})` `topology.dart:10,13`; `optimize(List<CamPath>)` `:15` |
| Вход → выход | `List<CamPath>` → `PatternResult`; мастер + параметры сетки → `List<CamPath>` слоя `ARRAY`; `List<CamPath>` → упрощённые `List<CamPath>` |
| Инварианты | замкнутые контуры > 5 мм² → полигоны, иначе полигонизация ломаных; группировка по W×H с округлением до целых мм, главная группа = этикетки; мастер — в буфере 0.2 мм (фолбэк 0.5 мм); при `isArray == false` `masterPaths` = сам контур, `rows = cols = count = 1`, шаги и зазоры = 0 (`pattern_recognition.dart:4-15,26-28`); порядок смещений `for c…for r: (c·stepX, −r·stepY)`, 4 знака (`array_generator.dart:36-38,18,48`); контуры < 2 точек отбрасываются (`topology.dart:18,27`) |
| Зависимости | `geom/*`, `model/*`; `TopologicalOptimizer` использует `pointSegmentDistance` и `simplifyRing` |
| Тесты | `pattern_test.dart` (1 OK); `healer_test.dart` покрывает `topology`; `optimizer_test.dart` — варианты раскроя (4 OK) |
| Подводные камни | контракт `agents/04` считал `quadroring.dxf` массивом — это не так, проверено оракулом (`docs/VERIFICATION.md:67`) |

---

## 6. `calculator/` — расход материала

| Пункт | Содержание |
|---|---|
| Назначение | Раскрой по параметрам машины: раппорт, ряды/колонки, обороты, длина, площади, отходы; форма этикетки; свод расхода; перебор вариантов |
| Математика (`material.dart:5-17`) | `rapport = Z·CP` (или ручной); `dPitch = rapport/π`; `dCyl = dPitch − 2·undercut`; `stepX = labelW + gapX`; `stepY(r) = rapport/r`; `gapYAct = stepY(r) − labelH ≥ minGap`; `cols ≤ floor((W_eff + gapX)/(labelW + gapX))`, `W_eff = min(цилиндр, полотно)`; `perRev = rows·cols`; `count`: `revs = ceil(N/perRev)`; `length`: `revs = floor(L/rapport)`; `area = length·webWidth`; `waste% = (1 − S_used/area)·100` |
| API | `computeRapportValue(z, cp, {manual = 0})` `:40`; `GearInfo` `:46-51` и `gearInfo(z, cp, undercut, {manual})` `:53`; `rowCandidates` `:67`, `colCandidates` `:75`, `pickRows` `:83`; `MaterialResult` (28 полей) `:105-146` и `MaterialResult.withError` `:149`; `computeMaterial(p, {rows, cols, rotated = false})` `:158`; `computeMaterialAuto(p)` `:279`; `LabelShape` `shape.dart:13-27`, `shapeFromPreset(kind, w, h, {radius = 0})` `:41`, `shapeFromPolygon(ring)` `:62`; `Consumption` `consumption.dart:15-33`, `computeConsumption(calc, shape)` `:35`; `enumerateVariants(p, {limit = 50})` `layout_optimizer.dart:20` |
| Вход → выход | `LayoutParams` (+ опц. `rows`/`cols`/`rotated`) → `MaterialResult`; `MaterialResult` + `LabelShape` → `Consumption`; `LayoutParams` → отсортированный `List<MaterialResult>` |
| Ошибки (`material.dart:167-208`) | «Раппорт должен быть больше нуля…»; «Этикетка высотой … не влезает в раппорт …»; «Фактический зазор по Y … меньше минимального …»; «Этикетка шириной … не влезает в ширину …»; «Используемая ширина … превышает доступную …»; «Длина полотна … меньше одного раппорта …». При ошибке числовые поля нулевые, `error != null` (`:103-104,149`) |
| Инварианты | округления: 4 знака — габариты, шаги, зазоры, `usedWidth`, `webMin`, `rapport`, `dPitch`, `dCyl`, `areaM2`; 2 знака — `length`, `areaMm2`, `usedAreaMm2`, `wastePct`, `perLabelArea` (`:246-274`); формы: `rect`/`polygon`/прочее → `w·h`, `roundRect` → `w·h − (4−π)·r²`, `circle`/`ellipse` → `π·(w/2)·(h/2)` (`shape.dart:34-55`); сортировка вариантов по `perLabelArea`, затем `wastePct`, стабильная, `limit = 0` — без ограничения (`layout_optimizer.dart:39-56`) |
| Зависимости | `model/params.dart`; внутри `calculator/` — `material.dart` в основе |
| Тесты | `material_test` 9, `optimizer_test` 4, `shape_test` 7 |
| Подводные камни | `countRequested` заполняется только в режиме `count` (в Python там `None`, в Dart 0) (`material.dart:239-241`); ошибочные варианты отбрасываются (`layout_optimizer.dart:34`), поэтому индексы `variants` не равны порядку перебора — сопоставление через `TeoComparison.bestIndex` |

---

## 7. `manufacturability/` — контроль технологичности

| Пункт | Содержание |
|---|---|
| Назначение | Собрать проверки в отчёт, вынести вердикт, дать авто-исправления |
| API | `AnalysisReport` (`issues`, `verdict`, `counts`, `ok`) `analyzer.dart:14-26`; `analyzeManufacturability(paths, p)` `:39-40`; `healGeometry(paths, p)` `:84-89`; `removeDustPaths(paths, minLoopArea)` `:92`; `applyIssueFix(paths, issue, p)` `:97-98`; проверки — `isDust` `geometry_checks.dart:92`, `checkDust` `:108`, `checkOpenPaths` `:131`, `checkIntersectionsDuplicates` `:240`, `checkSharpCorners` `:378`, `checkSmallGaps` `:600` |
| Порядок проверок | open → dust → intersection/duplicate → sharp_corner → small_gap (`analyzer.dart:30-31,49-55`) |
| Вход → выход | `List<CamPath>` + `ManufacturingParams` → `AnalysisReport`; `healGeometry` → новая `List<CamPath>`; `applyIssueFix` → новая геометрия (для неисправимых — исходная, `:107`) |
| Вердикт (`:62-73`) | есть `error` → «Требует исправлений (N критич.)», `ok = false`; иначе есть `warning` → «Внимание (N предупреждений)», `ok = true`; иначе «Технологично», `ok = true` |
| Авто-фиксы (`:99-107`) | `dust` → `removeDustPaths`; `open`/`intersection`/`duplicate` → `healGeometry`; остальное — без изменений |
| Зависимости | `model/*`, `healer/morphology`, `optimizer/topology`, `geometry_checks` |
| Тесты | `manufacturability_test.dart` (10 OK) |
| Производительность | порог `kHeavyPointSkip = 120000` суммарных точек: при превышении проверка «малых зазоров» **пропускается** (`analyzer.dart:33-47`) — она квадратична и на гигантах занимала 90–280 с (коммит `2f1513c`); пары ищутся через `_nearSegmentPairs` (`geometry_checks.dart:482`), пересечения/дубликаты — через bbox-сетку |
| Подводные камни | пропуск проверки малых зазоров не отражается в `AnalysisReport` — вердикт может быть лучше фактического |

---

## 8. `economics/` — статьи затрат и ТЭО

| Пункт | Содержание |
|---|---|
| Назначение | Сортамент и машины как данные, JSON-каталог, расчёт себестоимости, сравнение вариантов, break-even |
| API | `AssortmentItem(id, name, pricePerM2, minOrderM2?)` `assortment.dart:8-19`; `Machine(id, name, ratePerHour, speedMetersPerMin?, labelsPerHour?, setupTimeHours, setupMaterialMeters)` `machine.dart:10-31`; `WorkTime(hoursPerShift = 8, shiftsPerDay = 1)` `:35-40`; `PriceCatalog` (`assortment`, `machines`, `workTime`, `currency = '₽'`), `toJson` `price_catalog.dart:26`, `fromJson` `:58`, `defaults()` `:110-149`; `TeoInput` `teo.dart:32-61`; `TeoResult` (17 полей) `:65-106` и `withError` `:105`; `computeTeo(calc, cons, input)` `:112`; `TeoComparison` `:186-208`; `compareTeoVariants(variants, consFor, input)` `:214-218`; `breakEvenQuantity(calcA, teoA, toolingA, calcB, teoB, toolingB)` `:275-282` |
| Формулы (`teo.dart:122-160`) | `runTime = length/(speed·1000)/60` **часов** (или `count/labelsPerHour`); `machineCost = (setup + run)·ratePerHour`; `materialCost = areaM2·pricePerM2 + setupMaterialMeters·(webWidth/1000)·pricePerM2`; `shiftsUsed = ceil((setup + run)/hoursPerShift)`, `shiftCost = shiftsUsed·shiftCostPerShift`; `markupCost = markupPct·(material+machine+tooling+shiftCost)/100`; `costPer1000 = totalCost/count·1000`; `shiftLoadPct = totalTime/(ч/смену·смен)·100` |
| Вход → выход | `MaterialResult` + `Consumption` + `TeoInput` → `TeoResult`; список вариантов + фабрика `Consumption` → `TeoComparison` |
| Инварианты | приоритет у `speedMetersPerMin`, если заданы и скорость, и `labelsPerHour` (`machine.dart:6-9`; `teo.dart:113-131`); `runTime` округляется до 4 знаков до расчёта `labelsPerHour` (`:158,163`), статьи затрат считаются по неокруглённым (`:134-153`); `compareTeoVariants` пропускает ошибочные, сортирует стабильно по `costPer1000`, `bestIndex` — индекс в **исходном** списке (`:190-195,236-245`); база экономии — лучший не-`rotated`, `savingsPer1000 ≥ 0` (`:247-256`); `breakEvenQuantity` → 0 при `denom ≤ 0` или `N* ≤ 0` (`:283-286`) |
| Зависимости | `calculator/material.dart`, `calculator/consumption.dart`; `dart:math` |
| Тесты | `economics_test.dart` (6 OK: `reference_teo`, `compare_variants`, `break_even`, `catalog_json`, `rounding`) |
| Подводные камни | `agents/07_economics.md` ошибочно приводил `runTime ≈ 0.3414 ч`, читая м/мин как м/ч; верна формула спеки §7 (`teo.dart:10-13`; `docs/VERIFICATION.md:68`) |

---

## 9. `reports/` — генераторы отчётов

| Пункт | Содержание |
|---|---|
| Назначение | Чистые генераторы «данные → байты/строка»: PDF ТЭО, XLSX, DXF |
| API | `TeoReportData` — 13 полей (`report_models.dart:14-43`); `TtfFont` (`glyphFor`, `advanceOfGlyph`, `widthPt`) `pdf_writer.dart:31,48,52,56`, `parseTtfFont(bytes, {name})` `:70`, `PdfDocument({pageWidth = 595, pageHeight = 842})` (`newPage`, `build`) `:262,278,387,397`, `PdfCanvas` (`text`, `rect`, `line`) `:457,466,493,501`; `translitRus` `teo_report.dart:16`, `buildTeoReportPdf(data, fontBytes)` `:81`; `crc32` `xlsx_writer.dart:31`, `ZipEntry` `:44`, `buildZip` `:153`, `colName` `:190`, `cellNumber` `:202`, `cellString` `:208`; `buildTeoXlsx(data)` `teo_xlsx.dart:197`; `buildDxfText(paths, {version = 'AC1015'})` `dxf_writer.dart:29` |
| Вход → выход | `TeoReportData` → `Uint8List` (PDF, XLSX); `List<CamPath>` → `String` (DXF). Файловую систему модули **не** трогают (`dxf_writer.dart:28`; `teo_report.dart:79-86`) |
| Инварианты | PDF 1.4: TTF как `FontFile2`, шрифт `Type0/CIDFontType2` с `Identity-H`, символ = 2 байта = gid из `cmap`, добавлен `/ToUnicode`; строки — hex `<…>`, экранирование не нужно (`pdf_writer.dart:1-11`); A4 595×842 pt (`:278`), нижняя граница вёрстки 806 (`teo_report.dart:100`); XLSX — листы «Расчёт», «ТЭО», «Варианты» (`teo_xlsx.dart:38-40`); DXF — HEADER (`$ACADVER`, `$INSUNITS=4`), TABLES, ENTITIES `LWPOLYLINE` (90 — вершин, 70 — замкнутость, 10/20 — координаты), 4 знака, не-ASCII слои `\U+XXXX`, пути < 2 точек пропускаются (`dxf_writer.dart:1-6,29-84,70`) |
| Зависимости | `model/`, `calculator/*`, `economics/*`; только stdlib (`dart:convert`, `dart:typed_data`, `dart:math`) |
| Тесты | `reports_test.dart` (5 OK) — структура PDF (проверяется PyMuPDF), структура XLSX (`zipfile`), roundtrip DXF, writer'ы на реальных данных; эталоны `test/golden/*` (`:104,148,199,283-285`) |
| Подводные камни | новый модуль отчётов нужно добавить и в баррель (`prepress_core.dart:33-38`), и в `io.dart`, если модулю нужен файл |

---

## 10. IO-фасад `lib/io.dart`

| Пункт | Содержание |
|---|---|
| Назначение | Единственное место пакета с `dart:io`: «путевые» API поверх чистых байтовых функций (`io.dart:5-10`) |
| API | `parseFile(String)` `:37-49`; `isPdfCompatible(String)` — 5 байт `%PDF-` `:52-67`; `fontPathForCyrillic()` — arial.ttf / DejaVuSans.ttf: системный каталог, `%LOCALAPPDATA%`, обход дерева глубиной 4 `:76-128`; `loadCyrillicFontBytes()` `:131-135`; `writeTeoReportPdf` (без шрифта — `StateError`) `:142-149`; `writeTeoXlsx` `:152-154`; `writeDxf` `:157-160`; расширения `DxfParserIo`/`SvgParserIo`/`PdfParserIo`/`AiPdfParserIo` с `.parse(path)` `:167-181` |
| Вход → выход | путь к файлу → `List<CamPath>`; данные отчёта + путь → файл на диске |
| Инварианты | **внутри файла только относительные импорты `src/…`**, не `package:` — иначе VM создаёт две копии классов и `ParserException` (`io.dart:16-19`); `parseFile` бросает `ParserException('Файл не найден: …')` и `'Ошибка при чтении файла: …'` `:39-47`; обход дерева пропускает `venv`, `node_modules`, `.git`, `build`, `.dart_tool` `:110-111` |
| Зависимости | `dart:io`, `dart:typed_data`; модули `src/…` относительно |
| Тесты | используется в 8 из 16 скриптов (`dxf_test`, `healer_test`, `manufacturability_test`, `parse_file_test`, `pattern_test`, `pdf_test`, `reports_test`, `svg_test`) |
| Подводные камни | в web-сборку файл не попадает (нет `dart:io`) — поэтому он и не в барреле |

---

## 11. Эталонные числа и как их проверить

**Вход:** 50×30 мм, `gapX = gapY = 3`, `minGap = 3`, `Z = 96`, `CP = 3.175`,
`undercut = 0.48`, цилиндр и полотно 300 мм, режим `count`, `N = 5000`
(`model/params.dart:18-33`). **Выход** — ассерты в `tool/e2e.dart:44-52`:

| Показатель | Значение |
|---|---|
| Раскладка | **9 рядов × 5 колонок** |
| Этикеток / оборотов | **5040 шт** / **112** |
| Длина полотна | **34137.6 мм** |
| Отходы / на этикетку | **26.18 %** / **2032.0 мм²** |
| Себестоимость 1000 шт | **704.88 ₽** (лучший вариант #1, экономия 0.0 ₽/1000) |

Допуски ассертов: `wastePct` и `perLabelArea` — ±0.05 (`e2e.dart:47-48`).

```powershell
# E2E — ЗАПУСКАТЬ ИЗ packages/core (путь к фикстурам = ../../fixtures, e2e.dart:8)
& '<корень>\.tools\dart-sdk\bin\dart.exe' tool/e2e.dart
#   → «Расход: 9×5, N=5040, оборотов=112, длина=34137.6, отходы=26.18%, на этикетку=2032.0»
#   → «ТЭО: costPer1000=704.88, лучший вариант #1 (704.88 ₽/1000), экономия 0.0 ₽/1000»
#   → «E2E OK» (код возврата 0)

powershell -File scripts/run_domain_tests.ps1           # 16 файлов; исторически ALL PASS
& '<корень>\.tools\dart-sdk\bin\dart.exe' test/material_test.dart   # один модуль
grep -riE 'uv_mask|gcode|g_code|уф|уп' packages/core/lib  # → 0 совпадений
& '…dart.exe' tool/profile_heal.dart "<файл>"  # тайминги: разбор / анализ / лечение
& '…dart.exe' tool/stat_analyze.dart "<файл>"  # тайминги по каждой проверке
```

| Тест → модуль | OK | Тест → модуль | OK |
|---|---|---|---|
| `dxf_test` → `parser/dxf` | 2 | `pattern_test` → `optimizer/pattern` | 1 |
| `svg_test` → `parser/svg` | 1 | `material_test` → `calculator/material` | 9 |
| `pdf_test` → `parser/pdf` | 1 | `optimizer_test` → `layout_optimizer` | 4 |
| `inflate_test` → `parser/inflate` | 7 | `shape_test` → `shape` + `consumption` | 7 |
| `parse_file_test` → диспетчер + AI | 7 | `manufacturability_test` | 10 |
| `geom_golden_test` → `geom/*` | 11 | `economics_test` → `economics/*` | 6 |
| `geom_smoke_test` → `geom/*` | 1 | `reports_test` → `reports/*` | 5 |
| `healer_test` → `healer` + `topology` | 6 | `sample_test` → `samples/` | 1 |

> Числа «OK» — из исторического прогона MVP (`docs/VERIFICATION.md:36-39`).
> Перед ссылкой на них в отчёте — прогнать `scripts/run_domain_tests.ps1`.
> Подробнее о тестовых уровнях и гейтах — `07_testing_quality.md`.

---

## 12. Приёмы и подводные камни (сводно)

| # | Приём | Почему |
|---|---|---|
| 1 | Баррель **не** экспортирует `io.dart` | в браузере нет `dart:io` (`prepress_core.dart:1-38`) |
| 2 | Внутри `io.dart` только относительные импорты | иначе две копии `ParserException` (`io.dart:16-19`) |
| 3 | Ядро работает с байтами, файл — только `io.dart` | один код на desktop и web (`parse_file.dart:8-9`) |
| 4 | Тесты — скрипты `void main()`, не пакет `test` | внешние зависимости запрещены (`pubspec.yaml:10-12`) |
| 5 | Ошибка расчёта — поле `error`, а не исключение | `MaterialResult.withError` / `TeoResult.withError` (`material.dart:149`; `teo.dart:105`) |
| 6 | Ошибка импорта — `ParserException` с русским текстом | показывается пользователю (`parse_file.dart:38,41,46`) |
| 7 | bbox-сетка вместо полного перебора пар | квадратичность на гигантах (`geom_boolean.dart:174-175,345`) |
| 8 | `kHeavyPointSkip = 120000` | пропуск «малых зазоров» вместо таймаута (`analyzer.dart:41`) |
| 9 | Стабильные сортировки вариантов | воспроизводимость относительно Python-эталона (`layout_optimizer.dart:39-41`; `teo.dart:236-242`) |
| 10 | 4 знака для координат, 2 — для денег | `vec2.dart:26`; `teo.dart:5`; `docs/HANDOFF.md:274` |
| 11 | `healGeometry` использует `tolerance = 2.0`, не дефолт 0.01 | рабочий режим мягче дефолта класса (`analyzer.dart:85-87`) |
| 12 | `lineMerge` не применяется в лечении | срезает замыкающий дубль (`morphology.dart:49-54`) |

---

## 13. Связанные документы

`00_architecture.md` (архитектура и потоки) · `02_data_formats.md` (форматы и
схемы) · `07_testing_quality.md` (уровни и гейты тестирования) · `README.md`
(индекс) · `agents/01_geometry.md`, `02_parsers.md`, `03_healer.md`,
`04_arrays.md`, `05_material_shape.md`, `06_manufacturability.md`,
`07_economics.md`, `08_reports.md` (исторические контракты) ·
`docs/VERIFICATION.md` (факты приёмки).
