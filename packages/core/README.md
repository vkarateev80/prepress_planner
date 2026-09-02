# prepress_core

Чистый Dart-домен «Препресс-Планер» (без Flutter, без сторонних зависимостей — pub.dev недоступен).

## Структура
- `lib/src/model/` — Vec2, CamPath, LayoutParams, ManufacturingParams, Issue
- `lib/src/geom/` — геометрическое ядро (агент 01)
- `lib/src/parser/` — DXF/SVG/PDF/AI-PDF парсеры (агент 02)
- `lib/src/healer/`, `lib/src/optimizer/` — лечение, топология, массивы (агенты 03–04)
- `lib/src/calculator/` — расход материала, форма, раскрой (агент 05)
- `lib/src/manufacturability/` — технологичность (агент 06)
- `lib/src/economics/` — ТЭО (агент 07)
- `lib/src/reports/` — PDF/XLSX/DXF (агент 08)

## Запуск тестов
`dart test` недоступен (нет пакета test). Каждый `test/*_test.dart` — исполняемый скрипт с `void main()` и хелперами из `tool/test_utils.dart`. Запуск из `packages/core`:

```powershell
& 'C:\Users\user\Desktop\MyApp\vibe cam\.tools\dart-sdk\bin\dart.exe' test\<file>_test.dart
# код выхода 0 = успех; в выводе «OK: <имя>» на каждую проверку
```

Все тесты (цикл):
```powershell
Get-ChildItem test -Filter *_test.dart | ForEach-Object {
  & 'C:\Users\user\Desktop\MyApp\vibe cam\.tools\dart-sdk\bin\dart.exe' $_.FullName
  if ($LASTEXITCODE -ne 0) { exit 1 }
}
```

## Правила
- Только стандартная библиотека Dart (dart:math, dart:io, dart:convert, dart:collection, dart:typed_data).
- Относительные импорты между файлами пакета.
- Координаты — мм, округление до 4 знаков; деньги — 2 знака; русские сообщения об ошибках.
- Запуск нативных команд в PowerShell: без `2>&1` и без пайпа их вывода (песочница).
