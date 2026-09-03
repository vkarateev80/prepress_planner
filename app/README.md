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
- `lib/license/` — клиент лицензий: `LicenseClient` (HTTP/офлайн-заглушка), `EntitlementStore`
  (кэш + грэйс 30 дн.), `FeatureGate` (Free/Pro, триал), `TrialTimer`, `LicenseController`
  (ChangeNotifier), `PaywallScreen` + хелперы `openPaywall`/`showProSheet`.

## Лимиты и гейтинг

- Триал 15 дней = полный доступ (`FeatureGate.hasProAccess`).
- Free: 1 проект, прямоугольный расчёт; остальное (Геометрия/ТЭО/Отчёты,
  «Перебор вариантов») → шторка «Доступно в Pro» → paywall.
- `LicenseController.purchase('month'|'year'|'restore')` — заглушка до IAP.

## Тесты

```bash
flutter pub get      # подтягивает prepress_core по path
flutter analyze      # 0 проблем
flutter test         # 15 тестов: widget_test (5), license_test (5), license_ui_test (5)
```

Данные приложения (проекты, состояние лицензии) хранятся в рабочих каталогах
`projects/` и `state/` относительно запуска — в проде перенести в профиль пользователя.
