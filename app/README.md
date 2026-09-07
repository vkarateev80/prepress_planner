# prepress_planner — Flutter-приложение «Препресс-Планер»

UI «Препресс-Планер» на Flutter. **Платформы:** Windows (desktop), Linux
(desktop), Web (браузер, `flutter build web`). Домен — локальный пакет
`packages/core` (path-зависимость в pubspec); внешних pub-пакетов нет.

## Структура

- `lib/main.dart` — вход: создаёт `ProjectStore('projects')` и
  `LicenseController` (кэш в `state/`, локальный офлайн-триал 15 дней при
  первом запуске, при наличии шлюза — восстановление сессии auth+payments).
- `lib/src/screens/home_shell.dart` — 5 вкладок: Проекты, Геометрия, Раскрой,
  ТЭО, Отчёты; кнопка аккаунта и чип статуса подписки в шапке; гейтинг
  Pro-вкладок (Геометрия, ТЭО, Отчёты).
- `lib/src/projects/project.dart` — `Project` + `ProjectStore`: один JSON на
  проект (`<имя>.json`, `schemaVersion: 2`), файлы на desktop /
  localStorage на web.
- `lib/src/screens/*` — экраны; `lib/src/widgets/*` — форма раскроя, таблица
  вариантов, canvas; `lib/src/logs/` — журнал событий (окно в шапке).
- `lib/src/converter/` — клиент к сервису конвертации: `ConverterApi`
  (HTTP-слой платформы: dart:io на desktop, XHR на web) для закрытых форматов
  AI/CDR/EPS → SVG; `ConverterServer` — проверка доступности и (desktop,
  локальный адрес) запуск локального uvicorn.
- `lib/license/` — аккаунт и подписка: `AccountGatewayHttp` (auth/payments),
  `LicenseController` (сессия, синхронизация подписки, покупка,
  офлайн-фолбэк), `EntitlementStore` (JSON-кэш), `FeatureGate` (Free/Pro,
  триал), `TrialTimer`, `AccountScreen`, `PaywallScreen` + хелперы
  `openPaywall`/`showProSheet`. `LicenseClient` — офлайн-заглушка
  (лицензионный сервер `services/license` клиентом **не вызывается**).
- `lib/platform/` — условные реализации по платформе: env, HTTP, JSON-хранилище,
  файлы, изоляты, сохранение отчётов.

## Платформы и адреса сервисов

- **Desktop (Windows/Linux):** адреса читаются из окружения —
  `PP_AUTH_URL`/`PP_PAYMENTS_URL`/`PP_CONVERTER_URL`; по умолчанию — прод
  `http://193.233.193.12:8121` (auth), `…:8122` (payments), `…:8120`
  (converter). Адрес конвертера можно поменять кнопкой-шестерёнкой на экране
  «Геометрия».
- **Web:** в браузере переменных окружения нет (`platform/env_web.dart`
  всегда возвращает `''`), поэтому клиент ходит **относительными путями**
  (`/auth`, `/payments`, `/convert`, `/data`) на тот же origin — нужен
  обратный прокси (nginx, см. `deploy/`). Данные — в localStorage.

## Импорт файлов

- DXF/SVG/PDF и PDF-совместимый AI разбираются локально доменом
  (`parseBytes`): на desktop — поле пути/выбор каталога на вкладке
  «Геометрия», на web — браузерный выбор файла.
- AI/CDR/EPS уходят на сервер конвертации (`services/converter`, см.
  `services/converter/README.md`): multipart-загрузка → SVG → разбор доменом.
  Если сервер недоступен, PDF-совместимый AI разбирается локально как
  запасной путь.

## Аккаунт, триал и гейтинг

- Аккаунты email+пароль на связке auth+payments; **серверные сессии, лимит
  устройств 1/1** (новый вход вытесняет прежние сессии).
- Триал 15 дней — локальный (создаётся при первом запуске без кэша);
  активный триал = полный доступ (`FeatureGate.hasProAccess`).
- Free: 1 проект + прямоугольный расчёт (`project.create`, `layout.rect`);
  остальное (вкладки Геометрия/ТЭО/Отчёты, «Перебор вариантов») → шторка
  «Доступно в Pro» → paywall.
- Оплата — **заглушка** на стороне payments (реальные деньги не списываются):
  `checkout` → `confirm`. `purchase('month'|'year'|'restore')` без сети —
  локальная заглушка.
- Список магнитных валов (Z) по умолчанию — `88, 96, 120, 176`
  (`layout_screen.dart`).

## Отчёты

Экран «Отчёты» (Pro/триал): генерация чистыми функциями ядра, кириллический
шрифт — `assets/fonts/DejaVuSans.ttf`. Файлы:
`04_ТЭО_Отчёт.pdf`, `05_Расчёт.xlsx`, `02_Вылеченный_Мастер.dxf` (+
`03_Раскрой.dxf`, если есть массив). Desktop пишет в каталог проектов, web —
скачивание браузером.

## Тесты

```bash
flutter pub get      # подтягивает prepress_core по path
flutter analyze      # 0 проблем
flutter test         # widget/unit-тесты (домен экранов, лицензия/аккаунт,
                     # конвертер, изоляты, web-смоук)
```

## Хранение данных

Проекты и состояние аккаунта/подписки: desktop — каталоги `projects/` и
`state/` **относительно текущего каталога запуска** (JSON-файлы; в проде
перенести в профиль пользователя); web — localStorage. Руководство
пользователя: `РУКОВОДСТВО_ПОЛЬЗОВАТЕЛЯ.md` в корне репозитория.
