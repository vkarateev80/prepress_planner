# 05. Платформы и сборки «Препресс-Планер»

**Статус: актуален на 2026-09-07 (HEAD bed533e)**

Документ описывает поддерживаемые платформы, окружение и версии SDK, пошаговые инструкции сборки (Windows/Linux/Web), запуск готовых сборок, переменные окружения по платформам, места хранения данных, особенности и «грабли», чек-лист проверки и известные проблемы. Все утверждения — со ссылками на файлы репозитория или на фактические артефакты в дереве.

## 1. Матрица платформ

| Платформа | Статус | Артефакт | Основание |
|---|---|---|---|
| Windows (desktop) | собирается и запускается | `app\build\windows\x64\runner\Release\prepress_planner.exe` | артефакт присутствует в дереве; `app/windows/CMakeLists.txt:7` (`BINARY_NAME prepress_planner`) |
| Linux (desktop) | собран локально в WSL Ubuntu 26.04, запускается ярлыком | `/home/dev/pp/app/build/linux/x64/release/bundle/prepress_planner` (в WSL) | `docs/HANDOFF.md:18-22, 240-242`, `docs/VERIFICATION.md:87` |
| Web (браузер) | собирается, раздаётся nginx на сервере | `app/build/web/` → статика на `http://193.233.193.12:8081` | `app/build/web/` (index.html, main.dart.js, canvaskit); `deploy/README.md:62` |
| iOS | только код, бинари не собирались | — | `docs/HANDOFF.md:20-22`, `docs/VERIFICATION.md:87` |
| macOS | только код, бинари не собирались | — | там же |
| ОС «Аврора» | открытый вопрос, работ не найдено | — | `docs/HANDOFF.md:294` |

Кроссплатформенность обеспечивается единым деревом Flutter-кода и условными импортами `app/lib/platform/*` (io/web-двойники), а не отдельными сборками — `docs/HANDOFF.md:39-54`.

## 2. Окружение и версии

| Компонент | Версия | Расположение | Основание |
|---|---|---|---|
| Flutter SDK (Windows/Web) | 3.47.2 stable, framework `d3b14c87…`, engine `a804b261…` | `.tools\flutter-src\flutter` | `.tools/flutter-src/flutter/bin/cache/flutter.version.json` |
| Dart SDK (домен) | 3.13.3 | `.tools\dart-sdk` | `.tools/dart-sdk/version` |
| Dart внутри Flutter | 3.13.2 | `.tools\flutter-src\flutter\bin\cache\dart-sdk` | `flutter.version.json` (`dartSdkVersion`) |
| Ограничение SDK приложения | `sdk: ^3.13.2` | `app/pubspec.yaml:8` | — |
| pub-cache | локальный | `.tools\pub-cache` | каталог присутствует в дереве |
| Python (сервисы, оракул) | 3.11.9 venv | `cam_pipeline\venv` (home `C:\Program Files\Python311`) | `cam_pipeline/venv/pyvenv.cfg` |
| Flutter Linux SDK | отдельный SDK в WSL | `/home/dev/flutter` (Ubuntu 26.04) | `docs/HANDOFF.md:172, 240` |
| Исходники для Linux-сборки | рабочая копия | `/home/dev/pp` | `docs/HANDOFF.md:173, 241` |
| Движки конвертера | Inkscape + Ghostscript 10.07.1 | `cam_pipeline\inkscape_engine`, `cam_pipeline\ghostscript_engine` | `docs/HANDOFF.md:175` |
| Внешние pub.dev-зависимости | отсутствуют (только `flutter` и локальный `prepress_core`) | `app/pubspec.yaml:10-16` | pub.dev недоступен в среде разработки |

Версии Dart не совпадают: SDK для домена — 3.13.3, встроенный в Flutter — 3.13.2 (`app/pubspec.yaml:8` требует `^3.13.2`). При прогоне домена вручную используется `.tools\dart-sdk` (`README.md:39-45`).

**Восстановление окружения на новой машине** (по `docs/HANDOFF.md:164-189`): быстрый вариант — скопировать каталог целиком (без `app/build`, `app/.dart_tool`, `services/*/data`, `*.db`); чистый вариант — `git clone`, затем Dart SDK в `.tools/dart-sdk`, Flutter stable в `.tools/flutter-src`, `flutter pub get` в `app/`, Python-venv с `pip install -r services/{converter,auth,payments,license}/requirements.txt`, движки Inkscape/Ghostscript (пути — через `PP_INKSCAPE`/`PP_GHOSTSCRIPT`) и отдельный Flutter Linux SDK в WSL.

## 3. Сборка Windows

1. Убедиться, что доступен Flutter из `.tools` (или из PATH): `.tools\flutter-src\flutter\bin\flutter.bat --version` — каталог содержит `flutter.bat`, `flutter`, `flutter-dev.bat` (`ls .tools/flutter-src/flutter/bin`).
2. Из каталога `app`: `flutter pub get` — подтягивает `prepress_core` по path-зависимости (`app/pubspec.yaml:15-16`, `README.md:50-54`).
3. Проверка перед сборкой: `flutter analyze` (ожидается 0 ошибок) и `flutter test` (`README.md:51-53`).
4. Сборка: `flutter build windows --release` (та же команда используется в CI — `.github/workflows/release.yml:29-30`).
5. Результат: `app\build\windows\x64\runner\Release\` — в дереве присутствуют `prepress_planner.exe` (≈91 КБ), `flutter_windows.dll` (≈21 МБ), `data\`, `native_assets.json`, а также рабочие папки `projects\` и `state\`.
6. Артефакт в CI выгружается из `app/build/windows/x64/runner/Release/` (`.github/workflows/release.yml:31-34`).

Пути с пробелами (`...\Desktop\DSH\vibe cam`) в командах Flutter проблем не создают, но для скриптов WSL/scp такие пути не годятся (см. §10).

### 3.1 Состав Windows-сборки

| Файл/каталог | Что это | Ссылка |
|---|---|---|
| `prepress_planner.exe` | исполняемый файл (имя задано `BINARY_NAME`) | `app/windows/CMakeLists.txt:7`, артефакт в дереве |
| `flutter_windows.dll` | движок Flutter для Windows | артефакт в дереве; `app/windows/flutter/ephemeral/flutter_windows.dll` |
| `data/` | ресурсы сборки: `app.so`, `icudtl.dat`, `flutter_assets/`, включая `flutter_assets/assets/fonts/DejaVuSans.ttf` (шрифт PDF) | `app/pubspec.yaml:25-28`; состав каталога проверен в дереве |
| `native_assets.json` | служебный манифест сборки | артефакт в дереве |
| `projects/`, `state/` | рабочие каталоги (появляются при работе приложения) | `app/lib/main.dart:37-41, 60` |
| `app/windows/runner/` | C++-обёртка окна (`win32_window.cpp/.h`), `CMakeLists.txt` | `app/windows/runner/CMakeLists.txt:9-40` |

## 4. Сборка сопутствующих частей: домен и сервисы

### 4.1 Домен (`packages/core`, чистый Dart)

| Шаг | Команда | Ожидаемый результат | Ссылка |
|---|---|---|---|
| Все тесты домена | `powershell -File scripts/run_domain_tests.ps1` (Linux/macOS — `bash scripts/run_domain_tests.sh`) | «ALL PASS (16 files)» | `scripts/run_domain_tests.ps1:11-24`, `README.md:39-45` |
| Один тест | `.tools\dart-sdk\bin\dart.exe test/material_test.dart` из `packages/core` | код выхода 0 | `README.md:41-43` |
| Эталонный E2E | `.tools\dart-sdk\bin\dart.exe tool/e2e.dart` из `packages/core` | эталонные числа расхода + `E2E OK`, код 0 | `docs/VERIFICATION.md:41-43` |
| Диагностика лечения/анализа | `tool/profile_heal.dart`, `tool/stat_analyze.dart` | профиль/статистика | `docs/HANDOFF.md:193-195`, `packages/core/tool/` |
| Золотые эталоны и проверка PDF (опционально) | `tool/gen_golden.py`, `tool/verify_pdf.py` через `cam_pipeline\venv\Scripts\python.exe` (shapely, ezdxf, PyMuPDF) | — | `packages/core/tool/`, `README.md:65` |

Тест-файл домена — самостоятельный скрипт (`void main()`), отдельного пакета `test` нет: запускается как `dart test/<file>.dart` (`docs/HANDOFF.md:39-43`). В `packages/core/test` — 16 файлов `*_test.dart`.

### 4.2 Сервисы (Docker/compose)

| Шаг | Команда/файл | Детали | Ссылка |
|---|---|---|---|
| Локальный стек без web | `cd services && cp .env.example .env && docker compose up -d --build` | converter 8120, auth 8121, payments 8122 | `services/docker-compose.yml:1-11` |
| Полный стек с web | `cd deploy && cp .env.example .env && docker compose up -d --build` | + nginx `8081:80` | `deploy/docker-compose.yml:1-14, 82-93` |
| Образы | `services/{converter,auth,payments,license}/Dockerfile` | `python:3.12-slim`; converter дополнительно ставит `inkscape`, `ghostscript`, `fonts-dejavu` | `services/converter/Dockerfile:6-13` |
| Процесс converter | `uvicorn converter_app.main:app --host 0.0.0.0 --port 8120 --workers 2` | два воркера + общий том (`PP_JOB_STORE=file`) | `services/converter/Dockerfile:29-31` |
| Процесс auth/payments | `uvicorn … --port 8121` / `--port 8122`, один воркер | — | `services/auth/Dockerfile:15`, `services/payments/Dockerfile:15` |
| Healthcheck | `python -c "urllib.request.urlopen('http://127.0.0.1:<порт>/healthz')"` каждые 15 с | 5 повторов, старт 5–10 с | `deploy/docker-compose.yml:27-33, 54-61, 73-80` |
| Первичная настройка сервера | `bash install_new_server.sh` (от root, идемпотентный) | ставит Docker, создаёт `.env` с `PP_AUTH_SECRET`, поднимает стек, ждёт healthy до 150 с | `deploy/README.md:41-48` |

## 5. Сборка Linux (через WSL)

Порядок, фактически использованный в проекте (Ubuntu 26.04 в WSL, отдельный Flutter Linux SDK):

1. Войти в WSL: `wsl.exe -d Ubuntu -u dev`.
2. Исходники лежат в `/home/dev/pp`, Flutter Linux SDK — в `/home/dev/flutter` (`docs/HANDOFF.md:172-173, 240-242`).
3. Сборка: `flutter pub get` и `flutter build linux --release` из `/home/dev/pp/app` (команды совпадают с CI — `.github/workflows/release.yml:46-48`; в CI дополнительно ставятся `ninja-build` и `libgtk-3-dev`, `release.yml:45`).
4. Результат: `/home/dev/pp/app/build/linux/x64/release/bundle/` — именно этот путь использует ярлык запуска (`.github/workflows/release.yml:52-53`; `C:\Users\vkara\Desktop\Препресс-Планер (Linux).cmd:9`).
5. Запуск из Windows — ярлык «Препресс-Планер (Linux).cmd» на рабочем столе: он задаёт `BUNDLE=/home/dev/pp/app/build/linux/x64/release/bundle` и выполняет `wsl.exe -d Ubuntu -u dev --cd %BUNDLE% -e %BUNDLE%/prepress_planner` (`.cmd:9-10`). Окно приложения появляется на рабочем столе Windows (WSLg), консоль cmd остаётся открытой и закрывается вместе с приложением (`.cmd:1-7`).

Windows-бинарь Linux-сборкой не заменяется: это отдельный SDK и отдельный вывод сборки.

## 6. Сборка Web

1. Из каталога `app`: `flutter pub get`, затем `flutter build web` (`deploy/README.md:27-33`).
2. Результат: `app/build/web/` — в дереве присутствуют `index.html`, `main.dart.js`, `flutter.js`, `flutter_bootstrap.js`, `flutter_service_worker.js`, `assets/`, `canvaskit/`, `manifest.json`, `version.json`.
3. Пометка для PDF: кириллический шрифт `assets/fonts/DejaVuSans.ttf` грузится через `rootBundle`, поэтому он попадает в web-сборку как asset (`app/pubspec.yaml:25-28`, `reports_screen.dart:122-133`).
4. Упаковка бандла развёртывания (из корня репозитория): `powershell -ExecutionPolicy Bypass -File deploy\build_bundle.ps1` (Linux/macOS — `bash deploy/build_bundle.sh`). Скрипт проверяет наличие `app\build\web\index.html`, копирует статику в `deploy/web`, пакует `services/{converter,auth,payments}` и создаёт `pp-new-server-stack.tar.gz` (`deploy/build_bundle.ps1:8-35`, `deploy/README.md:22-34`).
5. Развёртывание на сервере: `scp pp-new-server-stack.tar.gz root@<IP>:/`, распаковка в `/stack`, `cd stack/deploy && bash install_new_server.sh` (`deploy/README.md:36-48`).
6. Раздача: nginx в контейнере `web` (`8081:80`) отдаёт статику из `./web` и проксирует `/auth`, `/payments`, `/convert`, `/data`, `/healthz` на имена сервисов (`deploy/docker-compose.yml:82-93`, `deploy/nginx/pp-web.conf:11-38`), `client_max_body_size 64m` (`pp-web.conf:40`).
7. Локально каталог `deploy/web` **отсутствует** — он создаётся только скриптом сборки бандла.

## 7. Запуск готовых сборок

| Сборка | Как запустить | Что должно лежать рядом |
|---|---|---|
| Windows | двойной клик по `app\build\windows\x64\runner\Release\prepress_planner.exe` | `flutter_windows.dll`, `data\`, каталоги `projects\`, `state\` (создаются при работе) |
| Linux (WSL) | ярлык «Препресс-Планер (Linux).cmd» либо `wsl.exe -d Ubuntu -u dev --cd <bundle> -e <bundle>/prepress_planner` | весь каталог `bundle` (`lib/`, `data/`) |
| Web | открыть `http://193.233.193.12:8081` в браузере | статика в `deploy/web` на сервере + запущенные converter/auth/payments |

Рабочие каталоги `projects/` и `state/` создаются рядом с запущенным приложением/рабочим каталогом (`app/lib/main.dart:37-41, 59-63`); на web их заменяет `localStorage` (§9).

## 8. Переменные окружения по платформам

**Клиент (приложение):**

| Переменная | Desktop | Web | Значение по умолчанию | Ссылка |
|---|---|---|---|---|
| `PP_CONVERTER_URL` | читается при старте | не читается | `http://193.233.193.12:8120` | `converter_api.dart:56-59`, `converter_server.dart:21-22` |
| `PP_AUTH_URL` | читается | не читается | `http://193.233.193.12:8121` | `account_client.dart:201-202` |
| `PP_PAYMENTS_URL` | читается | не читается | `http://193.233.193.12:8122` | `account_client.dart:326-327` |
| `PP_CONVERTER_PYTHON` | путь к venv-python для локального uvicorn | нет | авто-поиск `cam_pipeline\venv\Scripts\python.exe` | `server_launch_io.dart:25-35, 105-120` |
| `USERPROFILE` | стартовый каталог диалога выбора файла | нет | каталог по умолчанию (`Directory.current`) | `files_io.dart:9-15` |

На web переменных окружения нет вовсе: `envOrDefault` всегда возвращает `''`, поэтому адреса становятся относительными и работают через прокси nginx (`platform/env_web.dart:6`, `platform/env.dart:11-12`, `deploy/README.md:80-83`).

**Сервисы (deploy/docker-compose и локальный запуск):** `PP_DATA_DIR`, `PP_JOB_STORE`, `PP_JOB_TTL_HOURS`, `PP_MAX_MB`, `PP_INKSCAPE`, `PP_GHOSTSCRIPT` (converter); `PP_AUTH_SECRET` (обязателен), `PP_TOKEN_TTL`, `PP_RESET_TTL`, `PP_SMTP_*`, `PP_SMTP_SSL` (auth); `PP_AUTH_URL` (обязателен), `PP_PUBLIC_BASE` (payments) — см. `docs/specs/04_services_api.md`, §2–4, и `deploy/.env.example`.

## 9. Где хранятся данные

| Данные | Desktop | Web | Ссылка |
|---|---|---|---|
| Проекты | `<каталог запуска>/projects/<имя>.json` (JSON v2) | `localStorage`: `pp_prepress_planner.projects/<имя>.json` | `main.dart:60`, `project.dart:292-317`, `platform/json_store_io.dart:6-46`, `platform/json_store_web.dart:10-27` |
| Подписка (кэш) | `state/entitlement.json` | `pp_prepress_planner.state/entitlement.json` | `main.dart:36`, `entitlement_store.dart:15-17` |
| Сессия аккаунта (токен) | `state/session.json` | `pp_prepress_planner.state/session.json` | `account_client.dart:87-109` |
| Идентификатор устройства | `state/machine_id.txt` | `pp_prepress_planner.state/machine_id.txt` | `license_client.dart:104-114` |
| Каталог материалов | `state/materials.json` | `localStorage`-ключ того же вида | `material_library.dart:23, 162-179` |
| Отчёты PDF/XLSX/DXF | файлы в каталоге `projects` (путь показывается в статусе) | скачивание браузером | `reports_screen.dart:109-110, 196-199`, `platform/save_out_io.dart:7-16`, `platform/save_out_web.dart:8-9` |
| Задача конвертации | `PP_DATA_DIR/out/<job_id>/…`, при `file` — `jobs/<id>.json` | — (серверная сторона) | `services/converter/converter_app/main.py:53-77, 143`, `jobs.py:154-177` |
| Аккаунты/заказы | `auth.db`, `payments.db` в томах `auth-data`, `payments-data` | — | `deploy/docker-compose.yml:52-53, 71-72` |

Дополнительно: на desktop функция `saveFileForUser` пишет в `%USERPROFILE%\Downloads`, но отчётами она не используется — только на web (`platform/files_io.dart:49-55`, `platform/save_out_web.dart:8-9`).

## 10. Особенности и «грабли»

1. **Пути с пробелами.** Рабочая копия — `C:\Users\vkara\Desktop\DSH\vibe cam`. Для сборочных команд Flutter это нормально, но для WSL/scp/ssh-скриптов требуется путь без пробелов: временные скрипты складываются в `C:\Users\vkara\.dsh-tmp` (`docs/HANDOFF.md:176, 251-253`).
2. **Аргументы ssh с кавычками ломаются** — сложные команды оформляются bash-скриптом в каталог без пробелов, заливаются по `scp` и запускаются на сервере (`docs/HANDOFF.md:251-253`).
3. **Пайпы нативных команд под песочницей DSH (Windows) дают EPERM** — вывод нативных программ (`git`, `ssh`, WSL и т.п.) нельзя захватывать конвейером и `2>&1`; запускать без захвата вывода или через файловый stdio (`docs/HANDOFF.md:248-250`).
4. **git «dubious ownership»** — добавлять `-c safe.directory` (или `-c safe.directory='*'`) (`docs/HANDOFF.md:255`).
5. **Только UTF-8.** PowerShell `Set-Content` портит кириллицу — файлы писать редактором/write-инструментом (`docs/HANDOFF.md:256-257`).
6. **Инструменты не в PATH, а в `.tools`** — Dart берётся как `.tools\dart-sdk\bin\dart.exe`, Flutter — как `.tools\flutter-src\flutter\bin\flutter.bat`; при отсутствии публикации в PATH команды `dart`/`flutter` могут не находиться (`README.md:39-45`, `.tools/dart-sdk/version`).
7. **Flutter Linux — отдельный SDK в WSL**; Windows-пути `/mnt/c/...` для сборки Linux не используются — проект собирается из `/home/dev/pp` (`docs/HANDOFF.md:172-173`).
8. **pub.dev недоступен** — внешние зависимости добавлять нельзя, всё построено на Flutter SDK и локальном `prepress_core` (`app/pubspec.yaml:10-11`).
9. **Локальный конвертер требует venv-python и каталога `services/converter`** рядом с деревом; путь ищется вверх до 12 уровней от exe и от текущего каталога (`server_launch_io.dart:90-131`). Если не найдено — сообщение с подсказкой «Запустите сервер вручную: uvicorn converter_app.main:app --port 8120» (`server_launch_io.dart:25-35`).
10. **Мусор не коммитить:** `app/projects/`, `app/state/`, `services/*/data/`, `*.db`, `__pycache__`, `.dart_tool`, `build/`, `.tools/`, `cam_pipeline/`, `cam_material/`, `*.tar.gz`, реальные `.env` (`docs/HANDOFF.md:270-273`).
11. **Web-сборка требует прокси** — относительные адреса (`/auth`, `/payments`, `/convert`, `/data`) работают только за nginx единого origin (`README.md:91`, `deploy/nginx/pp-web.conf:11-38`).
12. **PowerShell/DSH:** `flutter test` и другие нативные команды запускать без конвейеров; вывод длинных сборок удобнее направлять в файл.

## 11. Чек-лист «собрать и проверить»

1. `git -C "<корень>" log -1 --oneline` — фиксируем HEAD (ожидается `bed533e`).
2. `powershell -File scripts/run_domain_tests.ps1` — тесты домена (`README.md:39-45`); Linux/macOS — `bash scripts/run_domain_tests.sh`.
3. `.tools\dart-sdk\bin\dart.exe tool/e2e.dart` из `packages/core` — эталонный E2E: «Расход: 9×5, N=5040, оборотов=112, длина=34137.6, отходы=26.18%, на этикетку=2032.0» (`docs/VERIFICATION.md:22, 41-43`).
4. `cd app; flutter pub get; flutter analyze; flutter test` — 0 ошибок анализа и зелёные тесты (`README.md:47-54`). В `app/test` — 11 файлов; статический подсчёт вызовов `test(`/`testWidgets(` в этой сессии дал 37 (фактический прогон не выполнялся; в проекте заявлено 36/36).
5. `cam_pipeline\venv\Scripts\python.exe -m pytest services/converter/tests -q` (и `auth`, `payments`, `license`) — тесты сервисов (`README.md:56-63`).
6. Сборка целевой платформы: `flutter build windows --release` / `flutter build linux --release` (в WSL) / `flutter build web`.
7. Проверка артефакта: наличие `prepress_planner.exe` в `Release\`, наличие `index.html` в `app/build/web/`.
8. Для локального конвертера: наличие `cam_pipeline\venv\Scripts\python.exe` и `services\converter\converter_app\main.py` (`server_launch_io.dart:92-103`); кнопка «Запустить сервер» в UI либо ручной `uvicorn converter_app.main:app --port 8120`.
9. Пробы живости (если нужен сервер): `curl -s http://127.0.0.1:8120/healthz`, `…:8121/healthz`, `…:8122/healthz`, `curl -o /dev/null -w '%{http_code}' http://127.0.0.1:8081/` (`deploy/README.md:104-114`).
10. Упаковка бандла: `deploy\build_bundle.ps1` — успех печатает «Bundle ready: …pp-new-server-stack.tar.gz (N MB)» (`deploy/build_bundle.ps1:34-35`).

## 12. Известные проблемы

1. **CI на GitHub ни разу не прогонялся** — репозиторий был запушен, но workflows `ci.yml`/`release.yml` не запускались (`README.md:78`, `docs/HANDOFF.md:67, 244`). В сервис-джобе учтён skipif-тест Inkscape (`docs/HANDOFF.md:262-263`).
2. **`deploy/web` в репозитории нет** — каталог появляется только после `build_bundle.ps1`; `docker compose up` без предварительной web-сборки раздаст пустой каталог (`deploy/build_bundle.ps1:10-13, 19`).
3. **Linux-сборка живёт только в WSL** по пути `/home/dev/pp/...`; в Windows-дереве каталог `app/build/linux` отсутствует, ярлык без WSL не работает (`C:\Users\vkara\Desktop\Препресс-Планер (Linux).cmd:9-10`).
4. **macOS/iOS/Аврора не собраны** — код кроссплатформенный, но бинарей нет; для iOS дополнительно нужны StoreKit/IAP и аккаунт разработчика (`docs/HANDOFF.md:292-294`).
5. **Расхождение версий Dart** (3.13.3 в `.tools` против 3.13.2 во Flutter) может давать разное поведение анализа/компиляции домена при прямых вызовах `.tools\dart-sdk`.
6. **`app/build`, `app/projects`, `app/state` не в git** — при чистом клоне проекта/сборок нет, требуется `flutter pub get` и повторная сборка (`docs/HANDOFF.md:166-189, 270-273`).
7. **Тяжёлые операции на web идут в главном потоке** (изолятов в браузере нет) — лечение/распознавание большого файла может «подвешивать» интерфейс (`platform/isolates_web.dart:1-5`).
8. **Сервер работает по http, TLS нет** — дефолтные адреса клиента указывают на `http://193.233.193.12:8120-8122`, трафик не шифруется (`docs/specs/04_services_api.md` §8; `SECURITY.md` К-3). Перевод десктопа на единый origin `:8081` запланирован в `SECURITY.md`, фаза 1.
