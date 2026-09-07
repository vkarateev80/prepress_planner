# Препресс-Планер

Приложение **препресс-планирования расходных материалов и технико-экономического обоснования (ТЭО)** тиражей этикеток: импорт чертежа → лечение геометрии → распознавание массива → раскрой (с рейтингом по магнитным валам) → перебор вариантов → ТЭО → отчёты PDF/XLSX/DXF.

**Платформы:** Windows (desktop), Linux (desktop), Web (браузер) — единый Flutter-код; бэкенд — микросервисы FastAPI.

---

## Карта репозитория

| Каталог | Что это |
|---|---|
| `packages/core` | Чистый Dart-домен (без Flutter): геометрия, парсеры DXF/SVG/PDF/AI, лечение, массивы, shape-расход, технологичность, экономика/ТЭО, отчёты (PDF/XLSX/DXF) |
| `app` | Flutter-приложение: проекты, геометрия, раскрой, ТЭО, отчёты; аккаунт и подписка Pro; сборки desktop (Windows/Linux) и web |
| `services/converter` | FastAPI: AI/CDR/EPS → SVG/PDF (Inkscape + Ghostscript), джобы, статика результатов |
| `services/auth` | FastAPI: аккаунты email+пароль — регистрация/вход, серверные сессии (opaque-токены, в БД sha256), сброс пароля, лимит устройств 1/1 |
| `services/payments` | FastAPI: подписка Pro (месяц 990 ₽ / год 9 900 ₽) — заказы, подтверждение (заглушка), вебхук (заглушка); токены проверяет через auth |
| `services/license` | FastAPI: лицензии (триал/ключи/webhooks) — в прод-стек **не входит** (см. `SECURITY.md`) |
| `deploy` | Комплект развёртывания: docker-compose (converter/auth/payments/web-nginx), nginx единого origin :8081, `install_new_server.sh`, `build_bundle.*`, README |
| `agents/00..14` | Контракты субагентов (история исполнения) |
| `docs/` | `HANDOFF.md`, `VERIFICATION.md`, `superpowers/specs|plans/` (спека и план) |
| `docs/superpowers` | Спека `2026-09-02-prepress-planner-design.md` и план `2026-09-02-prepress-planner.md` |
| `.github/workflows` | `ci.yml`, `release.yml` |
| `fixtures/`, `samples/` | Эталонные файлы и образцы |

**Ключевые документы (корень):**
- `SECURITY.md` — аудит безопасности 2026-09-07 и план устранения;
- `РУКОВОДСТВО_ПОЛЬЗОВАТЕЛЯ.md` / `.pdf` — руководство пользователя;
- `deploy/README.md` — развёртывание стека.

**Легаси-эталон** (не в git): `cam_pipeline/`, `cam_material/`, `spec.md`, `SPECIFICATION.md` — исходный Python-код и спека старой версии, из которых портирован домен (нужны только как оракул сверки).

---

## Запуск тестов

### Домен (packages/core, чистый Dart)

```powershell
powershell -File scripts/run_domain_tests.ps1     # все тесты
# или из packages/core по одному:
& '..\..\.tools\dart-sdk\bin\dart.exe' test\material_test.dart
```

Linux/macOS: `bash scripts/run_domain_tests.sh`.

### Flutter-приложение (app)

```powershell
cd app
flutter pub get      # подтягивает prepress_core по path-зависимости
flutter analyze      # 0 ошибок
flutter test         # widget/unit-тесты
```

### Сервисы (pytest)

```powershell
& 'cam_pipeline\venv\Scripts\python.exe' -m pytest services/converter/tests -q
& 'cam_pipeline\venv\Scripts\python.exe' -m pytest services/auth/tests -q
& 'cam_pipeline\venv\Scripts\python.exe' -m pytest services/payments/tests -q
& 'cam_pipeline\venv\Scripts\python.exe' -m pytest services/license/tests -q
```

Python (для генерации золотых эталонов и верификации PDF): `cam_pipeline\venv\Scripts\python.exe` (shapely, ezdxf, PyMuPDF).

---

## Состояние проекта

- **Фазы 0–5 (фундамент, домен, экономика/отчёты, UI, сервисы, CI/верификация)** — выполнены; приёмка — `docs/VERIFICATION.md`.
- **Аккаунты и подписка (email+пароль, сессии, сброс пароля, лимит устройств 1/1)** — выполнено: сервисы `auth`+`payments`, UI аккаунта/paywall; оплата — заглушка до подключения платёжного провайдера.
- **Web-версия** — выполнено: `flutter build web`, единый origin через nginx (`deploy/nginx/pp-web.conf`).
- **Развёртывание** — полный стек поднят на сервере **193.233.193.12**: converter :8120, auth :8121, payments :8122, web :8081 (`http://193.233.193.12:8081`). См. `deploy/README.md`.
- **Сборки:** Windows — `app\build\windows\x64\runner\Release\prepress_planner.exe`; Linux — через WSL (ярлык «Препресс-Планер (Linux)» на рабочем столе); web — статика на сервере.
- **Раскрой:** список магнитных валов по умолчанию — `88, 96, 120, 176` (коммит `448dcba`).
- **Безопасность:** аудит 2026-09-07 выполнен, исправления отложены — см. `SECURITY.md`.
- **Git:** репозиторий GitHub `vkarateev80/prepress_planner`, ветка `master`, запушено (HEAD `448dcba`).

## Сквозной сценарий (домен)

Импорт DXF/SVG/PDF → анализ ошибок → лечение → распознавание массива/генерация сетки → расчёт раскроя (эталон: 50×30, зазоры 3, Z=96, CP=3.175, N=5000 → 9×5, 112 оборотов, 5040 этикеток, длина 34137.6 мм, отходы 26.18 %, на этикетку 2032.0 мм²) → перебор вариантов → ТЭО (сортамент, машины, переналадка, рабочее время) → отчёты PDF/XLSX/DXF.

Проверка: `dart packages/core/tool/e2e.dart` (из `packages/core`) — выход 0.

## Известные ограничения

- Оплата Pro — тестовая заглушка (реальные деньги не списываются).
- Forgot-password работает без SMTP в dev-режиме (код показывается на экране) — см. `SECURITY.md` К-1.
- Весь стек работает по http (TLS не настроен, домена нет) — см. `SECURITY.md`.
- Web-версия требует обратного прокси (nginx) — зашитые адреса сервисов в браузере не используются.
