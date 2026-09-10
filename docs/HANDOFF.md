# HANDOFF — передача контекста «Препресс-Планер» (снимок 2026-09-07)

> **Для кого:** новая сессия агента (или разработчик) на другом компьютере.
> Этот файл — полный слепок контекста проекта на 2026-09-07: что сделано, где лежит,
> как проверить, что переносить, какие грабли окружения встречены.
> Прочитайте его целиком перед любой работой. Дополняет `README.md`, `SECURITY.md`
> и `docs/VERIFICATION.md` (там — фактическая приёмка).

- **Дата подготовки:** 2026-09-07. Снимок состояния на коммит `448dcba`
  («Раскрой: список магнитных валов по умолчанию — 88, 96, 120, 176»), ветка `master`;
  удалённый GitHub `https://github.com/vkarateev80/prepress_planner.git`, запушено.
- **Обновление после снимка (2026-09-07):** затем в `master` добавлены партии
  документации и правок: `48f018c` (актуализация README/HANDOFF/VERIFICATION/
  SECURITY, руководство пользователя, `agents/*` + `.env` в `.gitignore`),
  `bed533e` (PDF-отчёт — линия таблицы больше не пересекает текст; ТЭО — свои
  материалы со спецификацией), а также комплект `УСТАВ.md`, `docs/specs/`,
  `docs/design/DESIGN_SYSTEM.md`. Актуальный HEAD смотрите командой
  `git log -1 --oneline`; спецификации ориентируются на `bed533e`.
- **ВАЖНО — состояние дерева:** партии документации (`48f018c`, `bed533e`) и
  комплект `УСТАВ.md` / `docs/specs/` / `docs/design/` закоммичены; перед началом
  работы всё равно проверяйте `git status` (в сессии могли остаться черновики).
- **Проект:** «Препресс-Планер» — приложение препресс-планирования расходных материалов
  и экономико-технического обоснования (ТЭО) тиражей этикеток.
- **Платформы (факт 2026-09-07):** собираются и работают **Windows** (desktop exe),
  **Linux** (desktop, собран локально в WSL Ubuntu 26.04; на рабочем столе Windows —
  ярлык «Препресс-Планер (Linux).cmd»), **Web** (`flutter build web`, раздаётся nginx
  на сервере). **iOS/macOS:** код кроссплатформенный (единое дерево Flutter), но
  бинари не собирались и не запускались.
- **Парадигма (утверждена заказчиком):** планирование расходных материалов препресса + ТЭО.
  УФ-маска и генерация УП/G-кода **намеренно удалены** из новой версии (остались только
  в легаси-эталоне).
- **Монетизация (утверждена):** аккаунты email+пароль; Free → Pro по подписке
  (месяц 990 ₽/30 дн., год 9 900 ₽/365 дн.); триал 15 дней; лимит устройств 1/1.
  Оплата — **заглушка** (реальный провайдер не подключён, см. `SECURITY.md`).

---

## 1. Карта репозитория

```
<корень>/                      = git-репозиторий (ветка master; HEAD 448dcba)
├── README.md                  обзор, карта, запуск тестов (обновлён 2026-09-07)
├── SECURITY.md                аудит безопасности 2026-09-07; исправления ОТЛОЖЕНЫ
├── РУКОВОДСТВО_ПОЛЬЗОВАТЕЛЯ.{md,pdf}  руководство пользователя (2026-09-07)
├── packages/core/             ЧИСТЫЙ Dart-домен (без Flutter, без pub.dev): модель, geom,
│                              parser, healer, optimizer, manufacturability, economics, reports
│   ├── test/*_test.dart       16 исполняемых тест-скриптов (void main(); не пакет test)
│   └── tool/                  e2e.dart (эталон), profile_heal.dart, stat_analyze.dart, test_utils.dart
├── app/                       Flutter-приложение (Windows/Linux desktop + Web)
│   ├── lib/main.dart          вход; LicenseController со старта (триал 15 дн.)
│   ├── lib/src/               screens (5 вкладок: Проекты/Геометрия/Раскрой/ТЭО/Отчёты),
│                              projects (store v2), widgets, logs (AppLog, log_window),
│                              converter (converter_api/server, server_launch_io/web)
│   ├── lib/license/           license_client, account_client, entitlement_store,
│                              license_controller, paywall_screen, account_screen
│   ├── lib/platform/          условные io/web-реализации (env, json_store, isolates,
│                              http, files, save_out) — основа Web-версии
│   └── test/                  11 файлов (widget, license, license_ui, license_account,
│                              converter_api/server, geometry_array, layout/teo-изоляты,
│                              import_flow, web_boot_smoke)
├── services/
│   ├── converter/             FastAPI: AI/CDR/EPS → SVG/PDF (пакет converter_app;
│                              Dockerfile: uvicorn --workers 2; requirements.txt)
│   ├── auth/                  FastAPI: аккаунты/сессии/сброс пароля/лимит 1/1 (auth_app)
│   ├── payments/              FastAPI: подписка Pro, заказы/confirm/webhook-заглушка (payments_app)
│   └── license/               FastAPI: лицензии (license_app) — в git есть, но в прод-композ
│                              deploy/ НЕ входит (см. SECURITY.md)
├── deploy/                    комплект развёртывания НОВОГО сервера:
│                              docker-compose.yml (converter/auth/payments/web), nginx/pp-web.conf
│                              (единый origin :8081), .env.example, install_new_server.sh,
│                              build_bundle.{ps1,sh} (архив pp-new-server-stack.tar.gz), README.md
├── scripts/run_domain_tests.{ps1,sh}   цикл по тестам домена
├── .github/workflows/{ci,release}.yml  CI (пока НЕ прогонялись на GitHub, см. §9)
├── fixtures/                  эталонные файлы тестов (в git)
├── samples/                   образцы (label_grid_5x6.svg/.eps)
├── agents/00..14.md           контракты субагентов (история исполнения)
└── docs/
    ├── HANDOFF.md             этот файл
    ├── VERIFICATION.md        приёмка §10 спеки (историч.) + доп. приёмка 2026-09-07
    └── superpowers/{specs,plans}/  спека и план MVP (2026-09-02)
```

Легаси-эталон (НЕ в git, `.gitignore`): `cam_pipeline/`, `cam_material/` — исходный
Python-код, из которого портирован домен; нужны только как оракул для сверки
(shapely/ezdxf/PyMuPDF), там же лежат движки конвертера (см. §4).

## 2. Статус проекта

### Базовые фазы Ф0–Ф5 (по «старой» спеке MVP) — выполнены

| Фаза | Содержание | Статус |
|---|---|---|
| Ф0 | git, монорепо, спека, план, контракты 00–14, фикстуры | ✅ (`2629ee9`) |
| Ф1 | домен: геометрия, парсеры DXF/SVG/PDF/AI, лечение, массивы, расход+shape, технологичность | ✅ |
| Ф2 | экономика/ТЭО + отчёты PDF/XLSX/DXF | ✅ |
| Ф3 | Flutter UI (MVP, 5 вкладок) | ✅ |
| Ф4 | конвертер + лицензии + подписка (триал 15 дн.) | ✅ |
| Ф5 | CI, E2E, верификация | ✅ (`6b274c0`) |

Историческая приёмка по §10 спеки зафиксирована в `docs/VERIFICATION.md` (часть A).
Точные промежуточные коммиты фаз — в `git log` (диапазон Ф0–Ф5 ≈ `2629ee9…6b274c0`).

### Дополнительно выполнено (после MVP, факты 2026-09-07)

| Что | Коммиты (выборка из git log) |
|---|---|
| Импорт AI/CDR/EPS из приложения (Ф6-01: конвертер + UI + таймауты) | `d3ea5e0` |
| Метры/м² в ТЭО и отчётах, приладка, смена и её цена | `8f17b55` |
| Массив «мастер+закон», журнал событий, ширина материала, рейтинг по Z, смена/ТЭО | `8a57827` |
| Ускорение лечения и анализа (bbox-сетки; лечение >90 с → ~16 с на файле) | `2f1513c` |
| Конвертер через удалённый Docker-сервер | `f730b17` |
| UI: адрес конвертера, VPS-дефолт, кнопка «Запустить сервер» | `ae0701a`, `1055103`, `15fe44a` |
| Аккаунты email+пароль и подписка Pro через микросервисы `auth`+`payments` | `61b4694`, `2255d2a` |
| Восстановление пароля (forgot/reset) и лимит устройств 1/1 | `4f0cd3e` |
| Web-версия + комплект развёртывания для нового сервера | `881cf72` |
| Раскрой: список магнитных валов по умолчанию `88, 96, 120, 176` | `448dcba` (**HEAD**) |
| Предыдущий HANDOFF (история) | `d04f31d` |

Плюс (документы/инфраструктура, часть — в незакоммиченной партии §шапки):
развёртывание полного стека на сервере **193.233.193.12** (см. §6), сборки
Windows/Linux/Web, руководство пользователя (`РУКОВОДСТВО_ПОЛЬЗОВАТЕЛЯ.md`/`.pdf`),
аудит безопасности `SECURITY.md` (**исправления отложены заказчиком** — ничего на
сервере/в коде без согласования не менять).

### Эталонные числа (самопроверка после переезда)

- Расход 50×30/зазоры 3/Z96/CP3.175/N5000: **9×5, N=5040, оборотов=112, длина=34137.6 мм,
  отходы=26.18%, на этикетку=2032.0 мм²/шт** — эти значения до сих пор зашиты в
  `packages/core/tool/e2e.dart` (assert) и в README.
- E2E печатает эталон и завершается `E2E OK`, код выхода 0 (детали вывода —
  `docs/VERIFICATION.md`).

## 3. Как проверить на новом месте

```powershell
# 1. Домен (из корня; dart берётся из .tools или PATH)
powershell -File scripts/run_domain_tests.ps1        # 16 файлов; исторически ALL PASS

# 2. E2E (из packages/core)
& '<корень>\.tools\dart-sdk\bin\dart.exe' tool/e2e.dart   # → E2E OK

# 3. Flutter (из app) — нужен Flutter SDK
flutter analyze      # → No issues found!
flutter test         # фактический вывод актуализировать после прогона

# 4. Сервисы (из корня; python = cam_pipeline\venv)
& 'cam_pipeline\venv\Scripts\python.exe' -m pytest services/converter/tests -q
& 'cam_pipeline\venv\Scripts\python.exe' -m pytest services/auth/tests -q
& 'cam_pipeline\venv\Scripts\python.exe' -m pytest services/payments/tests -q
& 'cam_pipeline\venv\Scripts\python.exe' -m pytest services/license/tests -q

# 5. Греп-контроль (в core нет маски/G-кода)
grep -riE 'uv_mask|gcode|g_code|уф|уп' packages/core/lib   # → 0 (кроме «управляющие
#    символы» в XML-комментарии)

# 6. Живой прод-стек (сервер 193.233.193.12) — ТОЛЬКО чтение/пробы:
ssh -i C:\Users\vkara\.ssh\pp_vps_ed25519 root@193.233.193.12   # вход по ключу
curl -s http://127.0.0.1:8120/healthz   # конвертер (на сервере; снаружи 8120)
curl -s http://193.233.193.12:8121/healthz  # auth
curl -s http://193.233.193.12:8122/healthz  # payments
curl -sI http://193.233.193.12:8081/        # web (200)
curl -s  http://193.233.193.12:8081/healthz # единый origin → конвертер
cd /stack/deploy && docker compose ps       # 4 контейнера (см. §6)
```

Числа тестов по коду на 2026-09-07 (без запуска): pytest-функций (`def test_`)
converter 11, auth 9, payments 8, license 10; `app/test` — 11 файлов, по коду
38 вызовов `test()`/`testWidgets()`. Фактические «passed» — только после прогона.

## 4. Инструменты и что переносить

**В git — только исходники + фикстуры.** Машинно-зависимое — НЕ в git:

| Что | Где | Примечание |
|---|---|---|
| Dart SDK 3.13.3 | `.tools/dart-sdk` (версия в `version`) | домен |
| Flutter 3.47.2 stable | `.tools/flutter-src/flutter` (`bin/cache/flutter.version.json`; engine `a804b261…`) | app (Windows/Web) |
| Flutter Linux SDK | WSL: `/home/dev/flutter` (Ubuntu 26.04) | Linux-сборка desktop |
| Исходники в WSL | `/home/dev/pp` | рабочая копия для Linux-сборок |
| Python venv (3.11.9) | `cam_pipeline/venv` (`pyvenv.cfg`) | pytest сервисов + оракул |
| Движки конвертера | `cam_pipeline/inkscape_engine`, `cam_pipeline/ghostscript_engine` | Inkscape + GS 10.07.1 |
| Временные скрипты | `C:\Users\vkara\.dsh-tmp` (путь БЕЗ пробелов) | для wsl/scp/ssh |

**Вариант A (быстрый, рекомендуется):** скопировать всю папку целиком (без `app/build`,
`app/.dart_tool`, `services/*/data`, `*.db`, `.tools` по желанию — пересоздаются).
Пути в коде/скриптах совпадают.

**Вариант B (чистый):** `git clone` + восстановить инструменты:
1. Dart SDK 3.13.3 → `.tools/dart-sdk` (или PATH);
2. Flutter stable (3.47.2, см. `flutter.version.json`), `flutter pub get` в `app/`;
3. Python 3.11+ venv + `pip install -r services/{converter,auth,payments,license}/requirements.txt`
   (+ для оракула: shapely ezdxf pymupdf);
4. Inkscape/Ghostscript — куда угодно, указать через `PP_INKSCAPE`/`PP_GHOSTSCRIPT`
   или положить в `cam_pipeline\*_engine` (авто-поиск);
5. Для Linux-сборки — WSL с отдельным Flutter Linux SDK.

## 5. Технические факты (для быстрого входа в код)

- **Домен:** только stdlib Dart; тест-файл = скрипт (`dart test/<file>.dart` из
  `packages/core`, код 0 = успех); баррел `prepress_core.dart`. Диагностика:
  `tool/profile_heal.dart`, `tool/stat_analyze.dart`.
- **UI:** `HomeShell`, 5 вкладок (NavigationRail на десктопе, NavigationBar на узком).
  Проекты — JSON v2 на диске (`app/projects/`). Аккаунт: регистрация/вход/выход,
  сессия в `app/state/session.json`; Pro-гейтинг: триал 15 дней или подписка,
  кэш `state/entitlement.json`, paywall в `lib/license/paywall_screen.dart`.
  Desktop-дефолты адресов сервисов зашиты (`http://193.233.193.12:8120-8122`) и
  переопределяются env `PP_CONVERTER_URL`, `PP_AUTH_URL`, `PP_PAYMENTS_URL`
  (`account_client.dart`, `converter_api.dart`, `converter_server.dart`).
  Web-версия адресов сервисов не содержит — единый origin `:8081`, платформенные
  вызовы — через `app/lib/platform/` (io/web).
- **services/auth:** FastAPI (`auth_app`). `register`/`login` (email+пароль,
  PBKDF2-SHA256 200 000 итераций), `logout`, `me`, `devices`, `verify` (внутренний,
  для payments), `forgot`/`reset`. Сессии: opaque-токены 256 бит, в БД только
  sha256; TTL 720 ч (`PP_TOKEN_TTL`); reset-код 6 цифр, TTL 30 мин (`PP_RESET_TTL`);
  лимит устройств 1/1 — новый вход с другим `device_id` вытесняет старую сессию.
  **Без SMTP `forgot` возвращает код в ответе (`dev_code`) — см. SECURITY.md К-1.**
- **services/payments:** FastAPI (`payments_app`). Тарифы `month` 990 ₽/30 дн.,
  `year` 9 900 ₽/365 дн. (`plans`, `subscription`, `checkout`,
  `orders/{id}/confirm`, `webhook`). Оплата — заглушка (провайдера нет); токен
  проверяется внутренним `POST {PP_AUTH_URL}/auth/verify`.
- **services/converter:** FastAPI (`converter_app`). `POST /convert`,
  `GET /convert/{job_id}`, `GET /healthz`; env `PP_MAX_MB` (50), `PP_JOB_STORE`
  (memory|file), `PP_JOB_TTL_HOURS` (24), `PP_INKSCAPE`/`PP_GHOSTSCRIPT`;
  в Dockerfile — `uvicorn --workers 2`.
- **services/license:** FastAPI (`license_app`). В git есть, в прод-композ НЕ входит;
  клиентом не вызывается; маршруты без auth; дефолтный секрет
  `dev-secret-change-me` — см. SECURITY.md §3.

## 6. Прод-сервер (факт 2026-09-07) и окружение

- **Сервер:** 193.233.193.12, Ubuntu 22.04, Docker + compose. Каталог стека `/stack`
  (структура `/stack/deploy` + `/stack/services`; разворачивался из
  `pp-new-server-stack.tar.gz`, собираемого `deploy/build_bundle.ps1`).
- **Контейнеры:** `deploy-converter-1` (:8120), `deploy-auth-1` (:8121),
  `deploy-payments-1` (:8122), `deploy-web-1` (nginx, 8081→80).
- **Web:** `http://193.233.193.12:8081` — единый origin: nginx проксирует
  `/auth`, `/payments`, `/convert`, `/data`, `/healthz` на имена сервисов
  (`deploy/nginx/pp-web.conf`) — без CORS.
- **`.env`** в `/stack/deploy`: `PP_AUTH_SECRET` — 64 hex-символа (сгенерирован
  `openssl rand -hex 32`); `PP_SMTP_*` — **пустые**. license-сервис **не развёрнут**.
- **SSH:** ключ `C:\Users\vkara\.ssh\pp_vps_ed25519` → `root@193.233.193.12`, без
  пароля. **ВНИМАНИЕ (активные дыры, исправления ОТЛОЖЕНЫ — SECURITY.md):**
  `PasswordAuthentication=yes`, `PermitRootLogin=yes`, fail2ban/ufw НЕ настроены,
  пароль провайдера НЕ сменён; на момент аудита шёл активный брутфорс SSH.
  Не менять серверную конфигурацию без явного согласования с заказчиком.
- **WSL (локально):** Ubuntu 26.04; Flutter Linux SDK `/home/dev/flutter`; исходники
  `/home/dev/pp`; ярлык рабочего стола Windows «Препресс-Планер (Linux).cmd»
  запускает Linux-сборку.
- **GitHub:** репозиторий `vkarateev80/prepress_planner` (ветка master), запушен;
  workflows `ci.yml`/`release.yml` на GitHub пока не прогонялись.

## 7. Грабли окружения (актуальные, 2026-09-07)

- PowerShell/песочница DSH на Windows: **нельзя пайпить вывод нативных команд и
  `2>&1`** (EPERM) — нативные программы (git, ssh и т.п.) запускать без захвата
  вывода или с файловым stdio.
- **ssh-аргументы с кавычками ломаются.** Сложные команды писать bash-скриптами в
  путь без пробелов `C:\Users\vkara\.dsh-tmp`, заливать на сервер по scp и запускать
  там `bash`.
- git на Windows: при «dubious ownership» добавлять `-c safe.directory` (или
  `-c safe.directory='*'`).
- Файлы только UTF-8; PowerShell `Set-Content` портит кириллицу — писать через
  редактор/write.
- **Не хранить askpass/pw-файлы** (временные — удалять, см. SECURITY.md §6);
  реальные `.env` — в `.gitignore` (в git только `.env.example`).
- Сервисы/веб на проде — по http; вся работа с сервером согласуется с SECURITY.md
  (исправления отложены заказчиком: «пока ничего не менять»).
- В CI-джобе сервисов тест `test_ai_to_svg_via_inkscape` скипается (skipif) без
  движка Inkscape на раннере — учитывать при активации workflows.

## 8. Конвенции проекта (соблюдать и дальше)

- Коммиты на русском, по одному на модуль/партию; git — журнал прогресса.
  **С 2026-09 стиль сообщений — без префиксов «Фх-уу»: короткие русские описания**
  (пример: «Раскрой: список магнитных валов по умолчанию — 88, 96, 120, 176»).
- Не коммитить: `app/projects/`, `app/state/`, `services/*/data/`, `*.db`,
  `__pycache__`, `.dart_tool`, `build/`, `.tools/`, `.dsh-tmp/`, `cam_pipeline/`,
  `cam_material/`, `*.tar.gz` (бандл `pp-new-server-stack.tar.gz`), реальные `.env`
  (правило добавлено в `.gitignore`; в git — только `deploy/.env.example`).
- Числа: координаты мм с 4 знаками, деньги 2 знака; тексты ошибок/UI/коммиты — русские.
- В `packages/core` не появляются модули УФ-маски и G-кода (греп-контроль).
- Документы держать в актуальном состоянии: `README.md`, `docs/HANDOFF.md`,
  `docs/VERIFICATION.md`, `SECURITY.md`, `deploy/README.md`.

## 9. Что дальше (открытые направления — выбирать заказчику)

1. **Безопасность — в первую очередь.** Фаза 1 (срочно: К-1…К-5, активные дыры) и
   Фаза 2 из `SECURITY.md`: код-фикс `forgot` (dev_code), SSH
   (PasswordAuthentication no, PermitRootLogin prohibit-password, fail2ban),
   ufw (22 + 8081), права/не-root, rate limiting, дефолты desktop → единый origin.
   Исправления пока ОТЛОЖЕНЫ заказчиком.
2. **SMTP / домен / TLS** — почты и домена у заказчика нет (блокер для forgot вне
   dev-режима и для https).
3. **Реальный платёжный провайдер** — сейчас `payments` — заглушка (Pro бесплатно,
   SECURITY.md К-4); подпись вебхуков.
4. **Судьба `services/license` и серверного энфорсмента Pro** — сейчас гейтинг
   клиентский (`state/entitlement.json` редактируем), license-сервер не развёрнут.
5. **macOS / iOS** — код кроссплатформенный, но бинари не собирались; для iOS —
   StoreKit/IAP и аккаунт разработчика Apple.
6. **ОС Аврора** — открытый вопрос (порт/запуск).
7. **CI на GitHub** — репозиторий запушен; прогонять `.github/workflows` (учесть
   skipif Inkscape в сервис-джобе).
8. **Руководство** — md и pdf созданы; при желании добавить скриншоты экранов.
9. Актуализировать числа тестов в `VERIFICATION.md` после свежих прогонов.

## 10. Ключевые документы

- Спека (MVP): `docs/superpowers/specs/2026-09-02-prepress-planner-design.md`
- План (MVP): `docs/superpowers/plans/2026-09-02-prepress-planner.md`
- Приёмка: `docs/VERIFICATION.md` (часть A — историческая приёмка §10; часть B — доп. 2026-09-07)
- Безопасность: `SECURITY.md` (аудит 2026-09-07; план Фаза 1/Фаза 2)
- Руководство пользователя: `РУКОВОДСТВО_ПОЛЬЗОВАТЕЛЯ.md` / `.pdf`
- Развёртывание: `deploy/README.md` (+ `deploy/docker-compose.yml`, `deploy/nginx/pp-web.conf`)
- README корня: `README.md`
- Контракты агентов: `agents/00..14.md` (история; новые работы не обязаны им следовать)

## 11. Что изменилось с прошлого HANDOFF (≈2026-09-03 → 2026-09-07)

Компактно; детали и порядок коммитов — в `git log` и `docs/VERIFICATION.md`:

- **Импорт AI/CDR/EPS из приложения** (Ф6-01, `d3ea5e0`): конвертер подключён к UI,
  поэтапные статусы, таймаут 90 с, авто-поиск Ghostscript.
- **Единицы и приладка (ТЭО)** (`8f17b55`): метры/м² в ТЭО и отчётах, расход на
  приладку, смена и её цена.
- **Массив «мастер+закон», журнал событий, ширина материала, рейтинг по магнитным
  валам, кнопка «Применить»** (`8a57827` и др.): режим работы только с мастером на
  слое `MASTER`, лента `AppLog` + окно журнала, блок «Ширина материала», блок
  «Рейтинг по Z», явное применение варианта раскроя.
- **Производительность лечения/анализа** (`2f1513c`): bbox-сетки в
  `geom_boolean.dart`/`morphology.dart`/`manufacturability`; результаты численно те же.
- **Конвертер — удалённый Docker-сервер** (`f730b17`), UI адреса и кнопка
  «Запустить сервер» (`ae0701a`, `1055103`, `15fe44a`).
- **Аккаунты и подписка Pro** (`61b4694`, `2255d2a`) + **восстановление пароля и
  лимит устройств 1/1** (`4f0cd3e`): сервисы `auth`/`payments`, экраны аккаунта и
  paywall, `session.json`, проверка токена `auth/verify`.
- **Web-версия и комплект развёртывания** (`881cf72`): `flutter build web`,
  `deploy/` (compose+nginx+bundle), развёртывание на **193.233.193.12**.
- **Z-список по умолчанию 88, 96, 120, 176** (`448dcba`, HEAD).
- **Документы 2026-09-07** (часть — незакоммичена, см. шапку): README, SECURITY.md,
  РУКОВОДСТВО_ПОЛЬЗОВАТЕЛЯ.md/.pdf, deploy/README.md, правки docs/ и agents/.
