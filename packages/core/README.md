# prepress_core

Чистый Dart-домен «Препресс-Планер» (без Flutter, без сторонних зависимостей —
pub.dev в среде недоступен). Код не зависит от платформы: работает и на
VM/desktop, и в web-сборке. **В баррель `lib/prepress_core.dart` не попадает
`dart:io`** (в браузере его нет); всё, что требует файловой системы, живёт в
отдельном IO-фасаде `lib/io.dart`, который импортируется только на VM/desktop
и в баррель не входит.

## Структура
- `lib/prepress_core.dart` — баррель (экспорты моделей, геометрии, парсеров,
  лечения, оптимизации, расчёта, технологичности, экономики, отчётов)
- `lib/io.dart` — IO-фасад (dart:io): `parseFile(path)`,
  `writeTeoReportPdf/writeTeoXlsx/writeDxf(out, …)`,
  `fontPathForCyrillic()`/`loadCyrillicFontBytes()` — **не в барреле**
- `lib/src/model/` — Vec2, CamPath, LayoutParams, ManufacturingParams, Issue
- `lib/src/geom/` — геометрическое ядро (агент 01)
- `lib/src/parser/` — DXF/SVG/PDF/AI-PDF парсеры (агент 02)
- `lib/src/healer/`, `lib/src/optimizer/` — лечение, топология, массивы (агенты 03–04)
- `lib/src/calculator/` — расход материала, форма, раскрой (агент 05)
- `lib/src/manufacturability/` — технологичность (агент 06)
- `lib/src/economics/` — ТЭО (агент 07)
- `lib/src/reports/` — PDF/XLSX/DXF (агент 08)

## Разбор файлов (байтовый API)

Все парсеры работают **только с байтами** (путей и `dart:io` в них нет):

```dart
List<CamPath> parseBytes(Uint8List bytes, String name)  // диспетчер по расширению
// и напрямую:
DxfParser().parseBytes(bytes) / SvgParser / PdfParser / AiPdfParser
```

- `.dxf/.svg/.pdf` — локальный разбор; `.ai` — как PDF, если файл начинается
  с `%PDF-` (`isPdfBytes`), иначе (и `.eps/.cdr`) — `ParserException`
  «требуется серверная конвертация» (конвертер `services/converter`).
- Путевые обёртки (`parseFile(path)` и т.п.) — только в `lib/io.dart`.

## Запуск тестов

`dart test` недоступен (нет пакета test). Каждый `test/*_test.dart` —
исполняемый скрипт с `void main()` и хелперами из `tool/test_utils.dart`;
золотые эталоны — в `test/golden/`. Запуск из `packages/core`:

```powershell
& dart test\<file>_test.dart
# код выхода 0 = успех; в выводе «OK: <имя>» на каждую проверку
```

Все тесты (цикл) — из корня репозитория:

```powershell
powershell -File scripts\run_domain_tests.ps1     # Windows
bash scripts/run_domain_tests.sh                  # Linux/macOS
```

(`dart` берётся из PATH либо из `.tools/dart-sdk/bin` — скрипты находят сами.)

## Правила
- Только стандартная библиотека Dart (dart:math, dart:convert,
  dart:typed_data); `dart:io` — только в `lib/io.dart`.
- Относительные импорты между файлами пакета; ко `dart:io`-модулям — только
  из VM-кода (в web-сборку `io.dart` не попадает).
- Координаты — мм, округление до 4 знаков; деньги — 2 знака; русские
  сообщения об ошибках.
