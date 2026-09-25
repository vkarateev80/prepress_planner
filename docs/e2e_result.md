# E2E-отчёт: расчётный путь «импорт → лечение → массив → раскрой → ТЭО → отчёты»

> Задача: `prj-prepress-saas:e2e-calculation-path` (отдел `fast-products`).
> Основание: **PRD v2 (approved)** §4.4/F-12, §4.5, §4.6, §10.2, §10.3;
> **System Design v1 (approved)** ADR-2, §3.3 (С4/С5), §3.4, §12.6.
> Дата прогона: 2026-09-24. Среда: macOS, Dart SDK 3.3.4 (`/Users/mac/flutter/bin/dart`),
> Python 3.9 (`services/api`, FastAPI), Docker недоступен.

Итог: **расчётный путь пройден, эталон PRD §10.2/§4.5 сошёлся 1:1 (delta = 0.0)**.
`packages/core` **не изменялся**. Полный браузерный путь (Flutter Web) —
вне этой задачи (`flutter-web-adapt`, статус `pending`).

---

## 1. Что проверено и чем

| # | Сценарий (PRD) | Команда проверки | Результат |
|---|---|---|---|
| 1 | Эталонная математика §10.2 (F-12, N-1) | `cd packages/core && dart tool/e2e.dart` | **PASS** (8 шагов, `E2E OK`) |
| 2 | Все тесты домена `packages/core` | `bash scripts/run_domain_tests.sh` | **PASS** (78 `OK`, `ALL PASS`) |
| 3 | Экономика: `computeTeo`/`compareTeoVariants`/`breakEvenQuantity` (F-14, F-15) | `dart test/economics_test.dart`, шаг 7 `tool/e2e.dart` | **PASS** (6 `OK`) |
| 4 | Отчёты PDF/XLSX/DXF (F-16, F-18) | `dart services/domain-worker/tool/verify_reports.dart` | **PASS** (22 проверки) |
| 5 | Импорт DXF/SVG/PDF → анализ → лечение → массив (F-1, F-5…F-9) | `dart services/domain-worker/tool/verify_calculation_path.dart` | **PASS** (144 проверки) |
| 6 | `domain-worker POST /calculate` (ADR-2) | `bash scripts/run_domain_worker_tests.sh` | **PASS** (`ALL PASS`, эталон delta 0.0) |
| 7 | `api → domain-worker` HTTP 200 + `state` (§12.6, §3.3 С5) | `bash scripts/run_api_e2e.sh` | **PASS** (живой воркер, delta 0.0) |
| 8 | Тесты `api` (включая доменные эндпоинты) | `cd services/api && python3 -m pytest tests -q` | **PASS** (54 passed) |
| 9 | Греп-контроль границ домена (0 mask/gcode) | `grep -rniE "mask\|gcode" packages/core/lib/` | **PASS** (0 совпадений) |
| 10 | Удаление зашитого IP `193.233.193.12` (ADR-1/ADR-6) | `grep -rn 193.233.193.12 app/lib services deploy` | **PASS** (только текст README об удалении) |

Суммарно: **298 автоматических проверок** (78 + 144 + 22 + 54) + живая HTTP-сверка.

---

## 2. Эталонные числа: ожидание vs факт (таблица сверки)

Источник фактов — живой путь `api → domain-worker → packages/core`
(`scripts/run_api_e2e.sh`): `POST /api/projects/{id}/calculate` с
`W=50, H=30, gap_x=3, gap_y=3, Z=96, CP=3.175, cyl=300, web=300,
mode=count, count=5000`.

| Показатель | Ожидание (PRD §10.2/§4.5) | Факт (HTTP) | delta | Статус |
|---|---|---|---|---|
| Ряды × колонки | 9 × 5 | 9 × 5 | 0 | **PASS** |
| Количество этикеток N | 5040 | 5040 | 0 | **PASS** |
| Обороты вала | 112 | 112 | 0 | **PASS** |
| Длина полотна, мм | 34137.6 | 34137.6 | 0.0 | **PASS** |
| Отходы, % | 26.18 | 26.18 | 0.0 | **PASS** |
| Площадь на этикетку, мм² | 2032.0 | 2032.0 | 0.0 | **PASS** |
| Раппорт, мм | 304.8 | 304.8 | 0.0 | **PASS** |
| `costPer1000`, ₽ | 704.88 | 704.88 | 0.0 | **PASS** |
| `totalCost`, ₽ | 3552.58 | 3552.58 | 0.0 | **PASS** |
| `machineCost`, ₽ | 2528.45 | 2528.45 | 0.0 | **PASS** |
| `materialCost`, ₽ | 1024.13 | 1024.13 | 0.0 | **PASS** |
| `runTimeHours`, ч | 0.0057 | 0.0057 | 0.0 | **PASS** |

Дополнительно воркер возвращает самопроверку
`metrics.reference = {checked: true, passed: true, delta: {…все 0.0}, eps: 0.005}`.
Точность: сравнение `abs(fact - expected) <= 1e-9` — **все 13 полей совпали
побитово** (точнее, без различия в double), требование N-1 «1:1» выполнено.

### 2.1 Перебор вариантов (F-11)

`POST /api/projects/{id}/variants` → 10 вариантов; лучший — базовый
`9×5`, отходы `26.18 %`, `704.88 ₽/1000`; экономия лучшего против базового
`0.0 ₽/1000` (совпадает с шагом 7 `tool/e2e.dart`). Повёрнутый вариант
`5×9` даёт те же отходы при `usedWidth = 294` мм.

### 2.2 Числа `dart tool/e2e.dart` (локальная сверка, шаг за шагом)

| Шаг | Результат |
|---|---|
| 1. Парсинг `quadroring.dxf` | 3 контура |
| 2. Анализ технологичности | `ok=true`, issues=1, вердикт «Внимание (1 предупреждений)» |
| 3. Лечение | 2 контура, оба замкнуты |
| 4. Массив | `isArray=false, count=0` (файл — не массив) |
| 5. Расход | `9×5, N=5040, 112 оборотов, 34137.6 мм, 26.18 %, 2032.0 мм²` |
| 6. Расход по форме | использовано 7 560 000 мм², отходы 26.18 % |
| 7. Варианты + ТЭО | `costPer1000=704.88`, лучший №1, экономия 0.0 |
| 8. Отчёты | PDF + XLSX + DXF записаны, `pdf.length > 1024`; `E2E OK` |

---

## 3. Отчёты (F-16, F-17, F-18)

`services/domain-worker/tool/verify_reports.dart` — 22 проверки, все PASS:

* **PDF ТЭО**: сигнатура `%PDF-`, CID-шрифт `/Type0`, кодировка `Identity-H`,
  карта `/ToUnicode`, встроенный subset `/FontFile2`, кириллица в UTF-16BE
  присутствует, файл завершён `%%EOF` (801 699 байт). Шрифт — комплектный
  `app/assets/fonts/DejaVuSans.ttf` (759 720 байт, сигнатура `00 01`).
  Кириллица **реально встроена**, а не заменена транслитом.
* **XLSX ТЭО**: валидный ZIP/OOXML (`PK\x03\x04`), `[Content_Types].xml`,
  9 листов `xl/worksheets/sheetN.xml` (12 212 байт).
* **DXF мастера**: `SECTION` … `EOF`, сущности `LWPOLYLINE`, файл читается
  обратно парсером без потерь (2 контура → 2).
* **Границы домена**: в PDF и XLSX нет `mask`/`gcode`.

---

## 4. Что сделано в этой задаче (код)

Проверка вскрыла реальный разрыв: **`services/api` не имел подключения к
`domain-worker`** (был только `DOMAIN_WORKER_URL` в конфиге и комментарий
«генерация появится вместе с domain-worker»), поэтому п.7 задания выполнить
«на существующем коде» было нельзя. Добавлено:

| Файл | Что |
|---|---|
| `services/api/api_app/domain.py` | **новый**: клиент `domain-worker` (`urllib`, stdlib): `POST /calculate`, русские ошибки, перевод контракта §12.6 (`layout_params`/`teo_input` snake_case → `params`/`teoInput` camelCase схемы `project_state.json v2`) |
| `services/api/api_app/main.py` | домен-клиент в рантайме (`STATE["domain"]`, `build_runtime`), обработчик `DomainError` (конверт §12.1), эндпоинты `POST /api/projects/{id}/{calc,variants,teo,teo/compare,pipeline,calculate}` |
| `services/api/tests/test_api_domain.py` | **новый**: 19 тестов (перевод контракта, эндпоинты + эталон, изоляция тенантов N-4, base64 макета F-1, русские ошибки воркера 422/503) |
| `scripts/run_api_e2e.sh` | **новый**: живая сверка `api → domain-worker → packages/core` (поднимает воркер на 8199, delta 0.0) |
| `services/domain-worker/tool/verify_calculation_path.dart` | **новый**: 144 проверки расчётного пути (импорт DXF/SVG/PDF → анализ → лечение → массив → раскрой → ТЭО, русские `Issue`) |
| `services/domain-worker/tool/verify_reports.dart` | **новый**: 22 проверки отчётов PDF/XLSX/DXF |
| `scripts/run_domain_worker_tests.{sh,ps1}` | новые тулзы включены в прогон |
| `services/api/README.md` | таблица эндпоинтов §12.6, раздел «Доменные расчёты», обновлён список оставшегося |
| `.gitignore` | локальная копия TTF (`/packages/core/assets/fonts/`) не коммитится |

**`packages/core` не изменялся ни в одном файле** (домен переиспользован как есть).
`orchestra_task` использован только для завершения `e2e-calculation-path`;
задача `flutter-web-adapt` не начиналась.

---

## 5. Замечания, отклонения и ограничения

1. **`flutter-web-adapt` не готова → полный браузерный путь не проверен.**
   UI всё ещё вызывает `services/converter` напрямую и не ходит в
   `/api/projects/...`. Проверен **серверный** расчётный путь (`api` →
   `domain-worker` → `packages/core`), то есть вся математика, которая в
   браузере не исполняется по ADR-2. Это соответствует границам задачи.
2. **Шрифт для PDF — зависимость среды, а не кода.** `fontPathForCyrillic()`
   (`packages/core/lib/io.dart`) ищет `arial.ttf`/`DejaVuSans.ttf` только в
   путях Windows (`C:\Windows\Fonts`, `%LOCALAPPDATA%`) и обходом дерева
   **вниз** от текущего каталога. На этом хосте (macOS) системного шрифта нет,
   поэтому для тестов рядом с `packages/core` положена копия комплектного
   `app/assets/fonts/DejaVuSans.ttf` (каталог в `.gitignore`). Код домена при
   этом не менялся, а web-путь вообще не зависит от этого поиска — в браузере
   шрифт приходит из `rootBundle` (`app/lib/src/screens/reports_screen.dart`).
   *Рекомендация (вне этой задачи):* для серверного пути (`domain-worker`,
   ADR-2) полезно добавить в `packages/core` явный `PP_FONT_PATH`/поиск вверх
   до корня репозитория — сейчас `writeTeoReportPdf` на хосте без Windows
   падает с понятной русской ошибкой, что для воркера в контейнере нужно
   закрыть копированием шрифта в образ.
3. **Генерация отчётов по запросу API не подключена.** Таблица `reports` и
   раздача (`GET /api/reports/{id}`, `.../download`) существуют, домен умеет
   строить PDF/XLSX/DXF (подтверждено), но эндпоинтов
   `POST /api/projects/{id}/reports/{pdf|xlsx|dxf}` (§12.8) с сохранением в
   объектное хранилище пока нет — это остаток для следующей задачи, а не
   дефект расчётного пути.
4. **Реальный `services/converter` в этой среде не запускался** (AI/CDR/EPS →
   SVG/PDF): его код требует Python 3.10+, локально доступен 3.9 (совпадает с
   ранее зафиксированным ограничением в `services/api/README.md`). Импорт
   открытых форматов (DXF/SVG/PDF) проверен на реальных фикстурах.
5. **Docker недоступен** → проверка топологии compose/nginx (единый origin 443,
   закрытые 8120/8121/8122) не выполнялась; она вне расчётного пути.
6. **`/calculate` без макета считает расчётную часть цепочки**
   (`calc → variants → teo`), потому что эталонный сценарий PRD §10.2 задаётся
   только параметрами раскроя, а стадии `parse`/`heal`/`pattern` без входной
   геометрии воркер справедливо отвергает («Не передан макет…»). При передаче
   `file_id`/`file_version_id` считаются все стадии (`all`).
7. **Кириллица в PDF проверена по факту встраивания** (`/Type0`, `Identity-H`,
   `/ToUnicode`, `/FontFile2`, UTF-16BE-глифы), но визуальный рендеринг
   (открытие в просмотрщике) в headless-среде не выполнялся.

---

## 6. Как воспроизвести

```bash
# 1. Эталон домена (эталон §10.2/§4.5)
cd packages/core && dart tool/e2e.dart                       # E2E OK

# 2. Все тесты домена
bash scripts/run_domain_tests.sh                             # ALL PASS (78 OK)

# 3. Воркер: тесты + эталон + расчётный путь + отчёты
bash scripts/run_domain_worker_tests.sh                      # ALL PASS (144 + 22 проверки)

# 4. Сквозной путь api → domain-worker (живой воркер, delta 0.0)
bash scripts/run_api_e2e.sh                                  # ALL PASS

# 5. Тесты api
cd services/api && python3 -m pytest tests -q                # 54 passed

# 6. Греп-контроль границ домена
grep -rniE "mask|gcode" packages/core/lib/                   # пусто
```
