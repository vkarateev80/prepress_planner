# Агент 02 — Парсеры (packages/core/lib/src/parser/)

## Роль
Порт парсеров из `cam_material/src/parser/` и `cam_pipeline/src/parser/` (Python) в чистый Dart. Локально: DXF, SVG, PDF, AI (PDF-совместимый). EPS/CDR и неподдерживаемые — понятное русское исключение «требуется серверная конвертация».

## Источники (читать и портировать семантику)
- `cam_material/src/parser/base_parser.py`, `dxf_parser.py`, `svg_parser.py`, `pdf_parser.py`, `geometry.py` (CamPath), `cam_material/src/pipeline_helpers.py` (диспетчер).
- `cam_pipeline/src/parser/ai_parser.py` (логика «AI с PDF-потоком»).
- Единицы: миллиметры, ось Y вверх; кривые дискретизируются в ломаные шагом 0.05 мм; координаты округляются до 4 знаков.

## Создаваемые файлы
```
packages/core/lib/src/parser/geometry.dart    // CamPath + Vec2 (если ещё нет — согласовать с аг.00/01)
packages/core/lib/src/parser/base_parser.dart // abstract BaseParser { List<CamPath> parse(String filePath); }
packages/core/lib/src/parser/dxf_parser.dart
packages/core/lib/src/parser/svg_parser.dart
packages/core/lib/src/parser/pdf_parser.dart
packages/core/lib/src/parser/ai_pdf_parser.dart
packages/core/lib/src/parser/parse_file.dart  // List<CamPath> parseFile(String path) — диспетчер по расширению
packages/core/lib/src/parser/parser_exception.dart // ParserException(String ruMessage)
packages/core/test/parser_test.dart
```

## Контракт
- `parseFile('.dxf'|'.svg'|'.pdf'|'.ai')` → локальный парсинг. Для `.ai`: если в начале файла есть `%PDF` — парсить как PDF; иначе `ParserException('AI без PDF-совместимости: требуется серверная конвертация')`.
- `.eps`, `.cdr`, прочие → `ParserException('Формат X: требуется серверная конвертация')` (русский текст).
- DXF: сущности LINE/LWPOLYLINE/POLYLINE/CIRCLE/ARC/SPLINE/ELLIPSE; масштаб по `$INSUNITS` (in→25.4, cm→10, m→1000); слой → `layerName`. Замкнутость по флагу LWPOLYLINE (70 бит 1) или совпадению концов (допуск 1e-6).
- SVG: минимальный XML-токенизатор (без сторонних пакетов) + разбор path (`M/L/H/V/C/S/Q/T/A/Z`, относительные варианты), фигуры circle/rect/ellipse/line/polyline/polygon, `transform` (matrix/translate/scale/rotate), viewBox/width → мм (25.4/96).
- PDF: разбор content-stream (операторы `m l c v y re h f s S n W`, `cm`-трансформации, `q Q`), масштаб pt→мм 25.4/72. Потоки: если FlateDecode — реализовать **свою распаковку DEFLATE (RFC 1951)** (допустимо: static-huffman+stored, dynamic — по возможности); если распаковка не реализована для конкретного файла — `ParserException` с текстом «PDF сжатие не поддерживается локально — используйте серверную конвертацию».
- Не бросать при «мусорных» сущностях — пропускать с записью в лог (возвращать также `List<String> warnings`? — нет, упрощение: молча пропускать нечитаемое; исключение только при полном провале).

## Тесты (пакет `test/`)
Оракул без Python: файлы quadroring.dxf/svg/pdf и petlya.* — **одна и та же геометрия в трёх форматах**:
1. Каждый парсер: файл существует, результат непуст, все координаты конечны, bounds > 0.
2. **Кросс-форматная сверка**: bbox (bounds) dxf ≈ svg ≈ pdf одного артворка в допуске 0.5 мм; количество замкнутых контуров согласуется (допуск ±10% из-за аппроксимации кривых).
3. Слой/закрытость: у quadroring.dxf есть замкнутые контуры (массив этикеток — ≥ 2 одинаковых bbox по ~размеру этикетки).
4. petlya_open_artifacts.dxf: есть НЕзамкнутые контуры (эталон для аг.03/06).
5. `.cdr`/`.eps` → ParserException с русским текстом (проверка сообщения).

## Критерии приёмки
1. Все тесты зелёные (раннер как у аг.01; при недоступности `dart test` — свой `tool/run_tests.dart`).
2. Только stdlib. Имена/пути точные. Коммит после зелёных тестов.
