# Препресс-Планер

Мультиплатформенное (iOS · Windows · macOS · Linux) приложение **препресс-планирования расходных материалов и экономико-технического обоснования (ТЭО)** тиражей этикеток.

- **Домен** (чистый Dart, без Flutter): `packages/core` — геометрия, парсеры (DXF/SVG/PDF/AI), лечение, массивы, shape-aware расход, технологичность, экономика/ТЭО, отчёты (PDF/XLSX/DXF).
- **Приложение** (Flutter UI): `app` — проекты, геометрия, раскрой, ТЭО, отчёты.
- **Сервисы** (FastAPI): `services/converter` (AI/CDR/EPS → SVG/PDF),
  `services/auth` (аккаунты email+пароль, организации/роли, серверные сессии),
  `services/payments` (подписка Pro: ЮKassa checkout/webhook/entitlement),
  `services/api` (проекты и файлы: гибрид S3 + PostgreSQL, изоляция по
  организации, вызов конвертера сервер-к-серверу — `services/api/README.md`).
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
& 'cam_pipeline\venv\Scripts\python.exe' -m pytest services/auth/tests -q
& 'cam_pipeline\venv\Scripts\python.exe' -m pytest services/payments/tests -q
& 'cam_pipeline\venv\Scripts\python.exe' -m pytest services/api/tests -q
```

Стек SaaS (PostgreSQL + MinIO + nginx TLS 443): `deploy/docker-compose.yml`,
описание — `deploy/README.md`, хранилище проектов/файлов — `services/api/README.md`.

Python (для генерации золотых эталонов и верификации PDF): `cam_pipeline\venv\Scripts\python.exe` (содержит shapely, ezdxf, PyMuPDF).

## Состояние

- Фаза 0 (фундамент) — выполнена.
- Фаза 1 (домен: геометрия, парсеры, лечение, массивы, расход+shape, технологичность) — выполнена, тесты зелёные.
- Фаза 2 (экономика/ТЭО, отчёты PDF/XLSX/DXF) — выполнена, тесты зелёные.
- Фаза 3 (Flutter UI) — выполнена, `flutter analyze` 0 ошибок, тесты зелёные.
- Фаза 4 (сервисы: конвертер, авторизация, оплата) — выполнена; converter/auth/payments
  развёрнуты на VPS (8120/8121/8122), pytest зелёные; оплата — заглушка до подключения провайдера.
- Фаза 5 (CI, сборка, верификация) — выполнена; CI в `.github/workflows`, приёмка в `docs/VERIFICATION.md`.
- SaaS-контур (PRD v2 / System Design v1): фундамент (`deploy/` — Compose + nginx TLS 443 + PostgreSQL + MinIO),
  auth (организации/роли, SMTP), billing (ЮKassa), **проекты и файлы в облаке** (`services/api`:
  гибрид S3+PostgreSQL, изоляция по `org_id`, версии, конвертер ADR-7) — реализованы;
  `domain-worker` (Dart VM + `packages/core`) и `flutter-web-adapt` — следующие задачи.

## Сквозной сценарий

Импорт DXF/SVG/PDF → анализ ошибок → лечение → распознавание массива/генерация сетки → расчёт раскроя (эталон: 50×30, зазоры 3, Z=96, CP=3.175, N=5000 → 9×5, 112 оборотов, 5040 этикеток, длина 34137.6 мм, отходы 26.18 %, на этикетку 2032.0 мм²) → перебор вариантов → ТЭО (сортамент, машины, переналадка, рабочее время) → отчёты PDF/XLSX/DXF.

E2E-проверка: `dart packages/core/tool/e2e.dart` (из `packages/core`) — выход 0.
