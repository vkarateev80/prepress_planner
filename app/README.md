# prepress_planner — Flutter-приложение «Препресс-Планер»

Мультиплатформенный UI (iOS · Windows · macOS · Linux) поверх домена `packages/core`
(path-зависимость в pubspec; внешних pub-пакетов нет).

## Структура

- `lib/main.dart` — вход: создаёт `ProjectStore('projects')` и
  `LicenseController` (`state/entitlement.json`, офлайн-триал 15 дней при первом запуске).
- `lib/src/screens/home_shell.dart` — 5 вкладок: Проекты, Геометрия, Раскрой, ТЭО, Отчёты;
  чип статуса подписки в шапке; гейтинг Pro-вкладок.
- `lib/src/projects/project.dart` — `Project` + `ProjectStore` (JSON v2 на диске).
- `lib/src/screens/*` — экраны; `lib/src/widgets/*` — форма раскроя, таблица вариантов, canvas.
- `lib/src/converter/` — HTTP-клиент к сервису конвертации (`ConverterApi`, dart:io, без
  внешних пакетов): импорт закрытых форматов AI/CDR/EPS → SVG. Зашитый IP удалён
  (ADR-6): на web дефолт — тот же origin (`/convert` через edge nginx), на
  desktop — локальный `http://127.0.0.1:8120`; переопределяется env
  `PP_CONVERTER_URL`. В SaaS-контуре конвертацию выполняет `services/api`
  сервер-к-серверу (`services/api/README.md`, ADR-7).
- `lib/license/` — аккаунт и подписка: `AccountGateway` (HTTP к микросервисам
  auth/payments), `LicenseController` (сессия, синхронизация подписки,
  покупка, офлайн-фолбэк), `EntitlementStore` (кэш + грэйс 30 дн.), `FeatureGate`
  (Free/Pro, триал), `TrialTimer`, `AccountScreen` (вход/регистрация),
  `PaywallScreen` + хелперы `openPaywall`/`showProSheet`. Адреса: env
  `PP_AUTH_URL`/`PP_PAYMENTS_URL` (desktop — локальные 8121/8122, web — тот же
  origin; зашитых IP нет). Desktop-клиент — совместимость: SaaS-путь (роли,
  организации, серверные сессии) подключает задача `flutter-web-adapt`.

## Импорт файлов

- DXF/SVG/PDF и PDF-совместимый AI разбираются локально доменом (поле пути на вкладке
  «Геометрия»).
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
