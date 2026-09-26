# prepress_planner — Flutter-приложение «Препресс-Планер»

Мультиплатформенный UI (iOS · Windows · macOS · Linux) поверх домена `packages/core`
(path-зависимость в pubspec; внешних pub-пакетов нет).

## Структура

- `lib/main.dart` — вход: создаёт `ProjectStore('projects')` и
  `LicenseController` (`state/entitlement.json`, офлайн-триал 15 дней при первом запуске).
  В web-сборке в store передаётся `ProjectsApi()` — проекты хранятся в
  `services/api` при активной сессии (env `PP_API_URL`, по умолчанию тот же
  origin `/api`); desktop и анонимный режим работают локально.
- `lib/src/screens/home_shell.dart` — 5 вкладок: Проекты, Геометрия, Раскрой, ТЭО, Отчёты;
  чип статуса подписки в шапке; гейтинг Pro-вкладок.
- `lib/src/projects/project.dart` — `Project` + `ProjectStore` (JSON v2). Два
  режима: локальный (JSON-файлы desktop / localStorage web) и облачный —
  `lib/src/projects/cloud_projects.dart` (`ProjectsApi`: CRUD `/api/projects`,
  Bearer-сессия, русские ошибки §12.1); режим выбирается по наличию api и
  токена (`flutter-web-adapt`).
- `lib/src/screens/*` — экраны; `lib/src/widgets/*` — форма раскроя, таблица вариантов, canvas.
- `lib/src/converter/` — HTTP-клиент к сервису конвертации (`ConverterApi`, dart:io, без
  внешних пакетов): импорт закрытых форматов AI/CDR/EPS → SVG. Зашитый IP удалён
  (ADR-6): на web дефолт — тот же origin (`/convert` через edge nginx), на
  desktop — локальный `http://127.0.0.1:8120`; переопределяется env
  `PP_CONVERTER_URL`. В SaaS-контуре конвертацию выполняет `services/api`
  сервер-к-серверу (`services/api/README.md`, ADR-7): `ApiConverter`
  (`api_converter.dart`) грузит файл в `POST /api/projects/{id}/files`
  (`convert=svg`) и забирает SVG из `GET /api/files/{id}/content`; при
  отсутствии сессии или облачного проекта — фолбэк на прямой `ConverterApi`.
- `lib/license/` — аккаунт и подписка: `AccountGateway` (HTTP к микросервисам
  auth/payments), `LicenseController` (сессия, синхронизация подписки,
  покупка, офлайн-фолбэк), `EntitlementStore` (кэш + грэйс 30 дн.), `FeatureGate`
  (Free/Pro, триал), `TrialTimer`, `AccountScreen` (вход/регистрация),
  `PaywallScreen` + хелперы `openPaywall`/`showProSheet`. Адреса: env
  `PP_AUTH_URL`/`PP_PAYMENTS_URL` (desktop — локальные 8121/8122, web — тот же
  origin; зашитых IP нет). Desktop-клиент — совместимость: облачное хранение
  проектов подключено в web-сборке (см. `ProjectStore`); серверная конвертация
  и скачивание файлов через `api` — остающиеся части `flutter-web-adapt`.

## Экспорт отчётов

- PDF ТЭО / XLSX / DXF: локально доменом (`heavy`, desktop — изолят) либо,
  в web-сборке при активной сессии, сервером — `POST /api/projects/{id}/reports/{fmt}`
  (`_cloudReport` в `lib/src/screens/reports_screen.dart`; PDF шлёт шрифт
  `font_base64`, DXF — состояние проекта с геометрией), затем скачивание
  `GET /api/reports/{id}/download`. Без сессии/проекта — прежний локальный путь.

## Импорт файлов

- DXF/SVG/PDF и PDF-совместимый AI разбираются локально доменом (поле пути на вкладке
  «Геометрия»). В web-сборке при активной сессии после разбора исходник
  автоматически загружается в `services/api` (`ProjectStore.uploadSource`,
  §12.5), `file_id` сохраняется в `Project.inputFileId` — кнопка
  «Скачать оригинал» на вкладке качает blob через `GET /api/files/{id}/download`.
- AI/CDR/EPS уходят на сервер конвертации (`services/converter`, см. `services/converter/README.md`):
  multipart-загрузка → SVG → разбор доменом. Если сервер недоступен, PDF-совместимый AI
  разбирается локально как запасной путь.

## Лимиты и гейтинг

- Триал 15 дней = полный доступ (`FeatureGate.hasProAccess`).
- Free: 1 проект, прямоугольный расчёт; остальное (Геометрия/ТЭО/Отчёты,
  «Перебор вариантов») → шторка «Доступно в Pro» → paywall.
- `LicenseController.purchase('month'|'year'|'restore')` — заглушка до IAP.

## Тесты

```bash
flutter pub get      # подтягивает prepress_core по path
flutter analyze      # 0 проблем
flutter test         # 21 тест: widget_test (5), license_test (5), license_ui_test (5),
                     #          converter_api_test (5), import_flow_test (1)
```

Данные приложения (проекты, состояние лицензии) хранятся в рабочих каталогах
`projects/` и `state/` относительно запуска — в проде перенести в профиль пользователя.
