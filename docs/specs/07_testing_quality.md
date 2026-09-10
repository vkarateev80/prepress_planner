# 07. Тестирование и качество (Testing & QA)

> **Статус: актуален на 2026-09-07 (HEAD bed533e)**
> Источники: `README.md` (§«Запуск тестов»), `docs/VERIFICATION.md` (части A и B),
> `docs/HANDOFF.md` (§3 «Как проверить», §5 технические факты), `scripts/run_domain_tests.ps1`,
> `packages/core/tool/e2e.dart`, `packages/core/test/reports_test.dart`,
> `packages/core/tool/verify_pdf.py`, `packages/core/tool/gen_golden.py`,
> `.github/workflows/{ci,release}.yml`, `SECURITY.md`.
> Числа «исторически» — это записанный вывод прогонов (`docs/VERIFICATION.md`);
> числа «по коду» — подсчёт объявлений тестов без запуска и помечены явно.

---

## 1. Принцип: что считается доказательством

1. Доказательство — **прогон с кодом выхода 0** и записанным выводом, а не факт наличия файла теста
   (`docs/VERIFICATION.md:90-95` прямо различает «по коду» и «после прогона»).
2. Прогон фиксируется в документах: `docs/VERIFICATION.md`, `docs/HANDOFF.md` §3.
3. Домен (Dart) устроен как **скрипты**: `dart test/<file>.dart` из `packages/core`, код 0 = успех
   (`docs/HANDOFF.md:193-195`); пакета `test` из pub.dev нет.
4. Тест, который нельзя запустить в CI без внешнего ресурса, помечается `skipif`, а не удаляется
   (`services/converter/tests/test_convert.py:61-63` — Inkscape; `docs/HANDOFF.md:262-263`).
5. «Требует проверки» пишется прямо там, где прогона не было. Ниже так помечены все непроверенные места.

---

## 2. Уровни тестирования: уровень → команда → что подтверждает → где результат

| Уровень | Команда (реальная) | Что подтверждает | Где результат / ссылка |
|---|---|---|---|
| **Домен** (16 файлов-скриптов) | `powershell -File scripts/run_domain_tests.ps1` (из корня) | Геометрия/лечение/массивы/раскрой/экономика/парсеры/отчёты целиком на чистом Dart | Цикл: `scripts/run_domain_tests.ps1:11-24`; исторически «ALL PASS (16 files)» — `docs/VERIFICATION.md:32-39` |
| **Домен, альтернатива** | `& '<корень>\.tools\dart-sdk\bin\dart.exe' test\<file>.dart` (из `packages/core`) | Один тест-файл отдельно (диагностика) | `README.md:39-45` |
| **E2E домена** | `& '<корень>\.tools\dart-sdk\bin\dart.exe' tool/e2e.dart` (из `packages/core`) | Сквозной сценарий + **эталонные числа**; код 0 | `packages/core/tool/e2e.dart:44-52,102`; вывод — `docs/VERIFICATION.md:41-50` |
| **Отчёты** | `dart test/reports_test.dart` (из `packages/core`) | Структура PDF (`%PDF-1.4`, `/Type0`, `/Identity-H`, `/ToUnicode`), XLSX (PK-zip, листы, эталонные значения), DXF round-trip, TTF-шрифт для кириллицы | `packages/core/test/reports_test.dart:102-307`; 5 проверок — `docs/VERIFICATION.md:25` |
| **UI (Flutter)** | `cd app && flutter analyze` | 0 ошибок анализатора (исторически 3 info про `dart:html`) | `README.md:47-54`; `docs/VERIFICATION.md:54` |
| **UI (Flutter)** | `cd app && flutter test` | Widget/unit-тесты: вкладки, форма параметров, варианты, canvas, store, лицензия, paywall, аккаунт, изоляты, импорт | `app/test/*.dart` (11 файлов); регистрация тестов — `README.md:50-54` |
| **Web-смоук** | входит в `flutter test` | `HomeShell` собирается на web-платформе | `app/test/web_boot_smoke_test.dart:11-15`; `docs/VERIFICATION.md:85` |
| **Сервисы** | `& 'cam_pipeline\venv\Scripts\python.exe' -m pytest services/converter/tests -q` | Конвертер: расширения/цель/пути `.ai`→PDF, Inkscape (skipif), ошибки, параллелизм, file-очередь | `README.md:56-63`; тесты — `services/converter/tests/test_convert.py`, `test_jobs.py` |
| **Сервисы** | `& 'cam_pipeline\venv\Scripts\python.exe' -m pytest services/auth/tests -q` | Регистрация/вход/`me`, лимит устройств 1/1, logout, verify, healthz, forgot/reset | `services/auth/tests/test_auth.py`; состав — `docs/VERIFICATION.md:82` |
| **Сервисы** | `& 'cam_pipeline\venv\Scripts\python.exe' -m pytest services/payments/tests -q` | checkout → confirm → subscription, продление цепочкой, отзыв токена, вебхук-заглушка, чужой заказ → 404 | `services/payments/tests/test_payments.py`; `docs/VERIFICATION.md:84` |
| **Сервисы (вне прода)** | `& 'cam_pipeline\venv\Scripts\python.exe' -m pytest services/license/tests -q` | Триал 15 дней, ключи, офлайн-токен | `services/license/tests/test_license.py`; сервис не в прод-стеке — `services/license/README.md:7-15` |
| **Прод-пробы** | `docker compose ps` + `curl …/healthz` (8120/8121/8122/8081) | Живой стек поднят и отвечает; защищённые маршруты → 401 | `deploy/README.md:104-114`; `docs/VERIFICATION.md:86` |
| **E2E на живом стеке** | ручной сценарий регистрация→вход→checkout→confirm→Pro | Связка auth+payments+клиент на проде | `docs/VERIFICATION.md:86` |
| **Вёрстка PDF** | аудит пересечений через PyMuPDF (§5) | Нет наложений линий на текст в PDF-отчёте (цель 0) | методика §5; баг найден этим приёмом и исправлен в `bed533e` |
| **CI** | `bash scripts/run_domain_tests.sh`, `flutter analyze/test`, `pytest converter+license` | То же, что локально, но на ранерах GitHub | `.github/workflows/ci.yml:8-54`; **на GitHub не прогонялись** — `docs/HANDOFF.md:243-244,295-296` |
| **Релиз** | `flutter build windows --release`, `flutter build linux --release` + `upload-artifact` | Сборки как артефакты релиза | `.github/workflows/release.yml:18-53`; сборки собраны вручную — `docs/VERIFICATION.md:87` |

---

## 3. Эталонные числа и правило их неизменности

Раскрой `LayoutParams()` по умолчанию (50×30, зазоры 3, Z=96, CP=3.175, N=5000):

| Величина | Эталон | Источник |
|---|---|---|
| Раскладка | 9×5 | `packages/core/tool/e2e.dart:44-46` |
| Этикеток | 5040 | там же |
| Оборотов | 112 | `README.md:82`, `docs/HANDOFF.md:121-123` |
| Длина, мм | 34137.6 | там же |
| Отходы, % | 26.18 | `packages/core/tool/e2e.dart:47` |
| На этикетку, мм² | 2032.0 | `packages/core/tool/e2e.dart:48` |
| `costPer1000`, ₽ | 704.88 | `docs/VERIFICATION.md:49`; комментарий эталона — `reports_test.dart:4-7` |
| `costPerLabel`, ₽ | 0.70 | `reports_test.dart:7` |
| `areaM2`, м² | 10.24128 | `reports_test.dart:7`; проверка в XLSX — `reports_test.dart:175` |
| ИТОГО, ₽ | 3552.58 | `reports_test.dart:174` |

Правило неизменности:

1. Эталон зашит как **assert с допуском 0.05** (`packages/core/tool/e2e.dart:44-52`) — молча
   изменить числа нельзя, прогон упадёт.
2. Эталонные значения дублируются проверками в отчётах (`reports_test.dart:170-175`) — расхождение
   между расчётом и отчётом тоже ловится.
3. Менять эталон можно **только** вместе с явным изменением физики (формула/параметр) и записью
   обоснования в `docs/VERIFICATION.md` (правило зафиксировано в `docs/HANDOFF.md:119-125`).
4. Значения в документах (`README.md:82`, `docs/HANDOFF.md:121-125`) должны обновляться в том же
   коммите, что и изменение эталона.

---

## 4. Golden-файлы

| Файл | Что это | Как появляется / обновляется |
|---|---|---|
| `packages/core/test/golden/geom_golden.json` | Эталон геометрии (Shapely): union/buffer/donut/круг | Генерируется `cam_pipeline\venv\Scripts\python.exe packages/core/tool/gen_golden.py` (`gen_golden.py:1-7,61-66`) |
| `packages/core/test/golden/deflate_cases.json` | Набор кейсов для проверки inflate/deflate-геометрии | Используется тестом `packages/core/test/inflate_test.dart` |
| `packages/core/test/golden/report_teo.pdf`, `report_teo_real.pdf` | PDF-отчёты реального расчёта | Перезаписываются прогоном `dart test/reports_test.dart` (`reports_test.dart:104,283`) |
| `packages/core/test/golden/report_teo.xlsx`, `report_teo_real.xlsx` | XLSX-отчёты | Там же (`reports_test.dart:148,284`) |
| `packages/core/test/golden/paths_roundtrip.dxf`, `label_contour_real.dxf` | DXF-контуры | Там же (`reports_test.dart:199,285`) |

Оговорка (важно): файлы в `test/golden/` по отчётам — это **выходные артефакты прогона**, а не
побайтовые эталоны: тест проверяет структуру и вхождения значений, а не совпадение с сохранённым
файлом (`reports_test.dart:102-307`). Побайтовое сравнение PDF/XLSX/DXF в репозитории отсутствует.

---

## 5. Методика аудита вёрстки PDF (пересечения линий и текста)

Назначение: ловить дефекты автоматической вёрстки PDF-ТЭО, которые структурные тесты
(`reports_test.dart`) не видят — например, **линия таблицы, пересекающая текст**. Именно этот
дефект был найден таким приёмом и исправлен в коммите `bed533e`
(«Отчёты: PDF — линия таблицы больше не пересекает текст…»).

Идея: «чернильная» зона каждого глифа/группы глифов берётся из `page.get_text('dict')`
(bbox span'ов), векторные отрезки — из `page.get_drawings()`; каждое пересечение тонкого
прямоугольника отрезка с bbox текста считается дефектом. **Целевое значение — 0 пересечений.**

Артефакты для проверки создаются прогоном `dart test/reports_test.dart`
(`packages/core/test/golden/report_teo.pdf`, `report_teo_real.pdf`) либо экспортом из приложения
(`app/lib/src/screens/reports_screen.dart:181-196`, файл `04_ТЭО_Отчёт.pdf`).

Эталонный текст-скрипт (подлежит добавлению в `packages/core/tool/` — сейчас в репозитории есть
только `verify_pdf.py`, который умеет лишь извлекать текст, `packages/core/tool/verify_pdf.py:1-29`):

```python
# -*- coding: utf-8 -*-
"""Аудит пересечений линий и текста в PDF-отчёте (PyMuPDF/fitz).

Запуск:  python tool/pdf_layout_audit.py <file.pdf>
Код выхода: 0 — пересечений нет (цель), 1 — есть, 2 — ошибка аргументов.
"""
import sys
import fitz  # PyMuPDF

LINE_W = 0.4  # pt: стремимся к «чернильной» толщине тонкой линии


def text_ink(page):
    """bbox «чернил» текста: span'ы с непустым текстом из get_text('dict')."""
    boxes = []
    for block in page.get_text("dict")["blocks"]:
        for line in block.get("lines", []):
            for span in line.get("spans", []):
                if span.get("text", "").strip():
                    boxes.append(fitz.Rect(span["bbox"]))
    return boxes


def segments(page):
    """Отрезки векторной графики: линии 'l' и стороны прямоугольников 're'."""
    segs = []
    for d in page.get_drawings():
        for item in d["items"]:
            if item[0] == "l":
                segs.append((item[1], item[2]))
            elif item[0] == "re":
                r = item[1]
                segs += [(r.tl, r.tr), (r.tr, r.br), (r.br, r.bl), (r.bl, r.tl)]
    return segs


def seg_rect(p, q):
    """Тонкий прямоугольник по отрезку p→q (координаты нормализует fitz.Rect)."""
    r = fitz.Rect(p.x, p.y, q.x, q.y)
    h = LINE_W / 2.0
    return fitz.Rect(r.x0 - h, r.y0 - h, r.x1 + h, r.y1 + h)


def main():
    if len(sys.argv) < 2:
        print("usage: pdf_layout_audit.py <file.pdf>", file=sys.stderr)
        return 2
    doc = fitz.open(sys.argv[1])
    total = 0
    for pno, page in enumerate(doc, start=1):
        ink = text_ink(page)
        hits = []
        for p, q in segments(page):
            r = seg_rect(p, q)
            for b in ink:
                if r.intersects(b):
                    hits.append((round(r.x0, 1), round(r.y0, 1),
                                 round(b.x0, 1), round(b.y0, 1)))
        print("страница %d: текстовых зон %d, пересечений %d" % (pno, len(ink), len(hits)))
        for x1, y1, x2, y2 in hits[:10]:
            print("  линия@%s,%s × текст@%s,%s" % (x1, y1, x2, y2))
        total += len(hits)
    print("ИТОГО пересечений: %d (цель — 0)" % total)
    return 0 if total == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
```

Ограничения методики (честно): проверяются только «чернила» текста и прямые отрезки; кривые Безье
(`item[0] == 'c'`), заливки и наложение текста на текст не проверяются; `LINE_W` — эвристика.
Порог для CI-гейта — **0 пересечений**, как в исходном аудите.

---

## 6. Гейты

### 6.1. Перед коммитом (минимальный набор)

| # | Гейт | Команда | Критерий |
|---|---|---|---|
| 1 | Домен | `powershell -File scripts/run_domain_tests.ps1` | `ALL PASS (16 files)`, код 0 |
| 2 | E2E/эталон | `dart tool/e2e.dart` (из `packages/core`) | `E2E OK`, эталон 9×5/5040/26.18/2032.0 |
| 3 | Анализ Flutter | `cd app && flutter analyze` | без ошибок (info допустимы и перечисляются) |
| 4 | Тесты Flutter | `cd app && flutter test` | все зелёные |
| 5 | Сервисы | `pytest services/<затронутый>/tests -q` | все зелёные; скип Inkscape — не ошибка |
| 6 | Доменный запрет | `grep -riE 'uv_mask\|gcode\|g_code\|уф\|уп' packages/core/lib` | 0 совпадений (кроме «управляющие символы» в XML-комментарии) — приём из `docs/HANDOFF.md:146-148` |
| 7 | PDF | аудит §5 на свежесобранном PDF | 0 пересечений |
| 8 | Документы | обновить числа/статусы в `README.md`, `docs/VERIFICATION.md`, `docs/HANDOFF.md` | правило `docs/HANDOFF.md:276-277` |

### 6.2. Перед релизом (дополнительно к 6.1)

| # | Гейт | Критерий/ссылка |
|---|---|---|
| 1 | CI-прогон `ci.yml` на GitHub (домен+flutter+сервисы) | **не подтверждён** — `docs/HANDOFF.md:243-244` |
| 2 | Сборка Windows/Web (`app/build/windows/x64/runner/Release/prepress_planner.exe`, `flutter build web`) | `docs/VERIFICATION.md:87`, `README.md:75` |
| 3 | Сборка Linux (WSL, `/home/dev/flutter`) | `docs/VERIFICATION.md:87`, `docs/HANDOFF.md:171-172` |
| 4 | Сверка SHA-256 артефактов (web-статика: `main.dart.js`) локально и на сервере | приём из `docs/VERIFICATION.md:85` |
| 5 | Обновление чисел прогонов в `docs/VERIFICATION.md` | `docs/HANDOFF.md:298` |
| 6 | Чек-лист безопасности релиза (10–15 пунктов) | `docs/specs/08_security.md` |
| 7 | Прод-пробы после деплоя | `deploy/README.md:104-114`, чек-лист дежурного — `docs/specs/06_deploy_ops.md` §8 |

---

## 7. Что не покрыто тестами (и почему)

| Область | Состояние | Почему/ссылка |
|---|---|---|
| Автотест вёрстки PDF | **нет** | Скрипт аудита в репозитории не закоммичен (`grep get_drawings` по `*.py` → совпадений нет); есть только извлечение текста `verify_pdf.py:1-29` |
| CI-гейт на аудит PDF | **нет** | `.github/workflows/ci.yml:8-54` такого шага не содержит |
| Прогон `ci.yml`/`release.yml` на GitHub | **не подтверждён** | `docs/HANDOFF.md:243-244,295-296` |
| Каталог материалов в UI (свои материалы, спецификация, `bed533e`) | **нет** | В `app/test` нет ни одного упоминания `MaterialLibrary` (проверено grep) |
| Редактируемый каталог машин | **нет** | Машины заданы только дефолтами в коде (`packages/core/lib/src/economics/price_catalog.dart:133-148`) |
| Экспорт сравнения вариантов | **нет** | Экспорт — только текущий проект: PDF/XLSX/DXF (`app/lib/src/screens/reports_screen.dart:158-176`) |
| Конвертер без движков на CI | частично | `test_ai_to_svg_via_inkscape` скипается по `skipif` (`services/converter/tests/test_convert.py:61-63`) |
| Прод-инфраструктура (ufw/TLS/бэкапы) | **нет** | Инфраструктурных тестов в репозитории нет |
| Нагрузка/DoS конвертера, rate limiting | **нет** | `SECURITY.md:21,25` (К-5, В-1) — тестов нет |
| Безопасность (аутентификация, права) | **нет** | Аудит — ручной документ `SECURITY.md` (2026-09-07) |
| macOS/iOS | **нет** | Бинари не собирались (`docs/VERIFICATION.md:87`) |
| Скриншотные/golden-тесты UI | **нет** | Только функциональные widget-тесты (`app/test/widget_test.dart`) |
| Побайтовое сравнение PDF/XLSX/DXF | **нет** | Проверяется структура и значения, не байты (§4) |

---

## 8. Правила добавления новых тестов

1. **Куда класть.** Домен (чистый Dart, без Flutter) — `packages/core/test/<тема>_test.dart`;
   UI/клиент — `app/test/<тема>_test.dart`; сервисы — `services/<сервис>/tests/test_<тема>.py`.
2. **Как называть.** Домен: файл-скрипт `*_test.dart` с `void main()`, вызываемым напрямую
   `dart test/<file>.dart`; имя теста внутри — короткое русское (`ok('pdf_structure')`,
   `reports_test.dart:139`). Flutter: `test('…')`/`testWidgets('…')` с русским описанием
   (`app/test/widget_test.dart:15-85`). Python: функция `def test_…` (подсчёт таких функций —
   принятая метрика, `docs/VERIFICATION.md:132-141`).
3. **Обязательность для новых фич.** Новая функциональность без теста не считается выполненной:
   приёмка ведётся таблицей «критерий → статус → команда/факт» (`docs/VERIFICATION.md:19-28,80-88`).
4. **Домен-файл обязан попасть в цикл**: имя `*_test.dart` в `packages/core/test/` автоматически
   подхватывается `scripts/run_domain_tests.ps1:11`; новый файл должен оставлять цикл зелёным.
5. **Внешние ресурсы** — только через `skipif` с понятной причиной, как
   `services/converter/tests/test_convert.py:61-63` (обязательно учесть в CI — `docs/HANDOFF.md:262-263`).
6. **Числа в тестах** — только из реального расчёта/эталона, с комментарием-источником
   (`reports_test.dart:4-7`), не «подогнанные» под результат.
7. **Артефакты** — писать в `test/golden/` (`reports_test.dart:311`) или во временный каталог
   (`e2e.dart:11`), не в корень репозитория.
8. **Язык** сообщений и имён тестов — русский (конвенции `docs/HANDOFF.md:265-277`).

---

## 9. Анти-регрессионные приёмы

| Приём | Как выполняется | Ссылка |
|---|---|---|
| **Grep-контроль запрещённого** | `grep -riE 'uv_mask\|gcode\|g_code\|уф\|уп' packages/core/lib` → 0 (УФ-маска и G-код намеренно удалены из версии) | `docs/HANDOFF.md:146-148,275` |
| **Сверка SHA-256 артефактов** | Хеш `main.dart.js` на сервере против локальной сборки | `docs/VERIFICATION.md:85` |
| **Сверка версий SDK** | Dart: `.tools/dart-sdk/version` = `3.13.3`; Flutter: `.tools/flutter-src/flutter/bin/cache/flutter.version.json` = `3.47.2 stable`, engine `a804b261…`, встроенный Dart `3.13.2` | файлы; расхождение 3.13.3/3.13.2 — ожидаемое |
| **Эталон с допуском** | assert в `e2e.dart` (допуск 0.05) падает при дрейфе математики | `packages/core/tool/e2e.dart:44-52` |
| **Дублирование эталона в отчётах** | Те же числа проверяются в PDF/XLSX | `reports_test.dart:170-175` |
| **Round-trip** | DXF: записали → распарсили → сверили контуры, слои, габариты, вершины (eps 1e-3) | `reports_test.dart:213-257` |
| **Побайтовые сигнатуры форматов** | `%PDF`, `%%EOF`, `PK\x03\x04`, `AC1015`, `\U+XXXX` для кириллицы | `reports_test.dart:111-123,155-168,204-210` |
| **Шрифт кириллицы** | Проверка наличия TTF > 50 КБ и сигнатуры `00 01` | `reports_test.dart:265-275` |
| **Живые прод-пробы** | healthz 200 + 401 на защищённых маршрутах после каждого деплоя | `deploy/README.md:104-114` |
| **Регулярное обновление чисел в документах** | Иначе документы начнут расходиться с кодом. Прецедент: HANDOFF фиксировал HEAD `448dcba` при фактическом `bed533e` — устранено 2026-09-07 блоком «Обновление после снимка» | `docs/HANDOFF.md:9-18` vs `git log` |
| **Ежедневный/релизный чек-лист** | Чек-лист дежурного и релизный чек-лист безопасности | `docs/specs/06_deploy_ops.md` §8, `docs/specs/08_security.md` |
