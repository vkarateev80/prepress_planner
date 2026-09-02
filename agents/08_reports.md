# Агент 08 — Отчёты: PDF ТЭО, XLSX, DXF (packages/core/lib/src/reports/)

## Роль
Генерация выходных артефактов в чистом Dart (только stdlib):
- **PDF ТЭО** — свой генератор PDF (формат PDF 1.4, текстовые + векторные операторы; шрифт — стандартный Helvetica, кириллица через кодировку (WinAnsi не содержит кириллицы — использовать **Identity-H + ToUnicode CMap** либо транслитерацию? РЕШЕНИЕ: кириллица через CID-шрифт Helvetica невозможна — использовать встроенный TrueType не выйдет без файла шрифта. Практичный выход: PDF-отчёт на русском с кириллицей через **Type0 с Identity-H** требует CMap/шрифт. Альтернатива: генерировать отчёт, где русский текст — в XLSX/CSV, а PDF — с **латиницей-транслитом заголовков + числами** + SVG-эскизом? НЕТ — требование заказчика: русский PDF. РЕШЕНИЕ: найти TTF с кириллицей в системе (C:\Windows\Fonts\arial.ttf / DejaVuSans.ttf), внедрить подмножество (CIDFontType2, Identity-H). Если шрифт найден — внедряем; тест проверяет, что файл открывается и содержит русские строки. Если нет — падать с понятной ошибкой. (аг.09/14 проверит открытие.)
- **XLSX** — «store»-zip (метод без сжатия: CRC32 табличный, local headers + central directory) + XML (workbook, worksheet, sharedStrings) — Excel открывает. Листы: «Расчёт», «Варианты», «ТЭО».
- **DXF** — writer: LWPOLYLINE по CamPath (порт вывода ezdxf из cam_pipeline), слои по layerName.

## Источники (читать)
- `cam_pipeline/src/pipeline/cam_pipeline.py` — сохранение 02_Вылеченный_Мастер.dxf (ezdxf LWPOLYLINE)
- `cam_pipeline/src/pipeline/report_generator.py` — структура отчёта (без ЧПУ-блоков)

## Создаваемые файлы
```
packages/core/lib/src/reports/pdf_writer.dart     // низкоуровневый PDF-писатель (объекты, xref, страницы, CID-шрифт)
packages/core/lib/src/reports/teo_report.dart     // компоновка отчёта ТЭО (русский)
packages/core/lib/src/reports/xlsx_writer.dart    // store-zip + xml
packages/core/lib/src/reports/teo_xlsx.dart
packages/core/lib/src/reports/dxf_writer.dart     // List<CamPath> → .dxf
packages/core/lib/src/reports/report_models.dart  // входные данные отчёта (проект, параметры, MaterialResult, TeoResult, Consumption, эскиз-полигоны)
packages/core/test/reports_test.dart
```

## Интерфейс (ТОЧНО)
```dart
void writeTeoReportPdf(String outPath, TeoReportData data);   // data — собранный report_models
void writeTeoXlsx(String outPath, TeoReportData data);
void writeDxf(String outPath, List<CamPath> paths, {String version = 'AC1015'}); // R2000
String fontPathForCyrillic();  // поиск: C:\Windows\Fonts\arial.ttf, DejaVuSans.ttf рядом, иначе null
```

`TeoReportData`: projectName, inputFile, LayoutParams, LabelShape, MaterialResult (выбранный), Consumption, TeoResult, TeoComparison (варианты), дата, AssortmentItem/Machine/WorkTime, currency.

## Содержимое PDF-отчёта (А4, русский)
Шапка (название, проект, дата) → Входные параметры (этикетка W×H/форма/S/efficiency, зазоры, шестерня, цилиндр/полотно, режим) → Расход (ряды×колонки, perRev, revs, N, длина, площадь м², использовано м², отходы % и м²) → Производство (машина, скорость, переналадка, машинное время, машиночасы ₽, загрузка смены) → Экономика (сортамент ₽/м², стоимость материала, оснастка, наценка, ИТОГО ₽, себестоимость 1000 шт) → Сравнение вариантов (таблица) → Эскиз (простая отрисовка bbox-рамок/контура линиями).

## Тесты
1. PDF: файл создан, начинается с `%PDF`, заканчивается `%%EOF`; размер > 1 КБ; содержит русскую строку проекта (проверка по подстроке в потоке контента при Identity-H — иначе проверять, что файл содержит `/Type0` и заголовок); открывается PyMuPDF (проверка агентом 14 или здесь через `cam_pipeline\venv\Scripts\python.exe -c "import fitz; ..."` — разрешено в тестах через отдельный скрипт tool/verify_pdf.py).
2. XLSX: файл — валидный zip (PK\x03\x04); распаковывается `Expand-Archive`/python zipfile; содержит [Content_Types].xml, workbook.xml, sheet1.xml со значениями 5040/26.18/1037.9 (примерные из аг.07).
3. DXF: текстовый, содержит `LWPOLYLINE` и координаты из входных путей; обратно парсится аг.02 DxfParser (round-trip: bounds совпадают).
4. Кириллица: если найден TTF — в PDF есть корректный русский текст (проверка через python fitz get_text).

## Критерии приёмки
1. Тесты зелёные. 2. Только stdlib. 3. Допуск округлений: деньги 2 знака.
