# Препресс-Планер

Мультиплатформенное (iOS · Windows · macOS · Linux) приложение **препресс-планирования расходных материалов и экономико-технического обоснования (ТЭО)** тиражей этикеток.

- **Домен** (чистый Dart, без Flutter): `packages/core` — геометрия, парсеры (DXF/SVG/PDF/AI), лечение, массивы, shape-aware расход, технологичность, экономика/ТЭО, отчёты (PDF/XLSX/DXF).
- **Приложение** (Flutter UI): `app` — проекты, геометрия, раскрой, ТЭО, отчёты.
- **Сервисы** (FastAPI): `services/converter` (AI/CDR/EPS → SVG/PDF), `services/license` (триал 15 дней, подписка Pro).
- **Легаси-эталон** (не в git): `cam_pipeline`, `cam_material` — исходный Python-код, из которого портируется домен.
- **Контракты субагентов**: `agents/00..14`.
- **Спека/план**: `docs/superpowers/specs/`, `docs/superpowers/plans/`.
- **Фикстуры**: `fixtures/` (эталонные файлы для тестов).

## Запуск тестов

### Домен (packages/core, чистый Dart)
Dart SDK: `.tools\dart-sdk\bin\dart.exe` (pub.dev недоступен — зависимости не используются).

```powershell
powershell -File scripts/run_domain_tests.ps1     # все тесты
# или из packages/core по одному:
& '..\..\.tools\dart-sdk\bin\dart.exe' test\material_test.dart
```

Linux/macOS: `bash scripts/run_domain_tests.sh`.

### Flutter-приложение (app)
Flutter SDK: `.tools\flutter-src\flutter\bin\flutter.bat` (путь зависит от среды).

```powershell
cd app
flutter pub get      # подтягивает prepress_core по path-зависимости
flutter analyze      # 0 ошибок
flutter test         # widget-тесты
```

### Сервисы (pytest)
Python venv: `cam_pipeline\venv\Scripts\python.exe` (fastapi/uvicorn/pytest/sqlalchemy/httpx установлены).

```powershell
& 'cam_pipeline\venv\Scripts\python.exe' -m pytest services/converter/tests -q
& 'cam_pipeline\venv\Scripts\python.exe' -m pytest services/license/tests -q
```

Python (для генерации золотых эталонов и верификации PDF): `cam_pipeline\venv\Scripts\python.exe` (содержит shapely, ezdxf, PyMuPDF).

## Состояние

- Фаза 0 (фундамент) — выполнена.
- Фаза 1 (домен: геометрия, парсеры, лечение, массивы, расход+shape, технологичность) — выполнена, тесты зелёные.
- Фаза 2 (экономика/ТЭО, отчёты PDF/XLSX/DXF) — выполнена, тесты зелёные.
- Фаза 3 (Flutter UI) — выполнена, `flutter analyze` 0 ошибок, тесты зелёные.
- Фаза 4 (сервисы: конвертер, лицензии, подписка) — в работе.
- Фаза 5 (CI, сборка, верификация) — в работе.

## Сквозной сценарий

Импорт DXF/SVG/PDF → анализ ошибок → лечение → распознавание массива/генерация сетки → расчёт раскроя (эталон: 50×30, зазоры 3, Z=96, CP=3.175, N=5000 → 9×5, 112 оборотов, 5040 этикеток, длина 34137.6 мм, отходы 26.18 %, на этикетку 2032.0 мм²) → перебор вариантов → ТЭО (сортамент, машины, переналадка, рабочее время) → отчёты PDF/XLSX/DXF.

E2E-проверка: `dart packages/core/tool/e2e.dart` (из `packages/core`) — выход 0.
