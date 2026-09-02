# Препресс-Планер

Мультиплатформенное (iOS · Windows · macOS · Linux) приложение **препресс-планирования расходных материалов и экономико-технического обоснования (ТЭО)** тиражей этикеток.

- **Домен** (чистый Dart, без Flutter): `packages/core` — геометрия, парсеры (DXF/SVG/PDF), лечение, массивы, shape-aware расход, технологичность, экономика/ТЭО, отчёты (PDF/XLSX/DXF).
- **Приложение** (Flutter UI): `app` — фаза 3.
- **Сервисы** (FastAPI): `services/converter` (AI/CDR/EPS → SVG/PDF), `services/license` (триал 15 дней, подписка).
- **Легаси-эталон** (не в git): `cam_pipeline`, `cam_material` — исходный Python-код, из которого портируется домен.
- **Контракты субагентов**: `agents/00..14`.
- **Спека/план**: `docs/superpowers/specs/`, `docs/superpowers/plans/`.
- **Фикстуры**: `fixtures/` (эталонные файлы для тестов).

## Запуск тестов домена

Dart SDK: `.tools\dart-sdk\bin\dart.exe` (скачан по http, т.к. https в среде заблокирован; pub.dev недоступен — зависимости не используются).

```powershell
# из packages/core — каждый тест-файл
& '..\..\.tools\dart-sdk\bin\dart.exe' test\sample_test.dart
# все тесты (ps1-цикл появится в фазе 5 / scripts/)
Get-ChildItem test -Filter *_test.dart | ForEach-Object {
  & '..\..\.tools\dart-sdk\bin\dart.exe' $_.FullName
  if ($LASTEXITCODE -ne 0) { exit 1 }
}
```

Python (для генерации золотых эталонов и pytest сервисов): `cam_pipeline\venv\Scripts\python.exe` (содержит shapely, ezdxf, PyMuPDF).

## Состояние

- Фаза 0 (фундамент) — выполнена.
- Фаза 1 (домен: агенты 01–06) — в работе.
