# 05. Платформы и сборки «Препресс-Планер»

**Статус: актуален на 2026-09-07 (HEAD bed533e)**

> **Мобильные версии добавлены 2026-09-07** (Android/iOS), сборка APK — §7, сборка iOS — §8.
> Правки лежат в рабочем дереве, коммит ещё не сделан; шапка (дата/HEAD) не менялась.
> Новые разделы: сборка Android — §7, сборка iOS (только macOS) — §8, CI `mobile.yml` — §9;
> данные на мобильных — §12, особенности — §13, чек-лист — §14, известные проблемы — §15.
> Файлы мобильного слоя: `app/android/`, `app/lib/platform/app_dirs*.dart`,
> `app/lib/platform/env*.dart`, `app/lib/platform/files_io.dart`, `app/lib/platform/save_out_io.dart`,
> `app/lib/main.dart`, `app/ios/Runner/Info.plist`, `.github/workflows/mobile.yml`.

Документ описывает поддерживаемые платформы, окружение и версии SDK, пошаговые инструкции сборки (Windows/Linux/Web/Android; iOS — только на macOS), запуск готовых сборок, переменные окружения по платформам, места хранения данных, особенности и «грабли», чек-лист проверки и известные проблемы. Все утверждения — со ссылками на файлы репозитория или на фактические артефакты в дереве.

## 1. Матрица платформ

| Платформа | Статус | Артефакт | Основание |
|---|---|---|---|
| Windows (desktop) | собирается и запускается | `app\build\windows\x64\runner\Release\prepress_planner.exe` | артефакт присутствует в дереве; `app/windows/CMakeLists.txt:7` (`BINARY_NAME prepress_planner`) |
| Linux (desktop) | собран локально в WSL Ubuntu 26.04, запускается ярлыком | `/home/dev/pp/app/build/linux/x64/release/bundle/prepress_planner` (в WSL) | `docs/HANDOFF.md:18-22, 240-242`, `docs/VERIFICATION.md:87` |
| Web (браузер) | собирается, раздаётся nginx на сервере | `app/build/web/` → статика на `http://193.233.193.12:8081` | `app/build/web/` (index.html, main.dart.js, canvaskit); `deploy/README.md:62` |
| Android (мобильный) | проект добавлен, **APK собран 2026-09-07** (`flutter build apk --release` — 1189,5 с; варианты по ABI — 71,3 с) | `app/build/app/outputs/flutter-apk/app-release.apk` (53,0 МБ, SHA-256 `dce60448…a3bf`) + `app-{arm64-v8a,armeabi-v7a,x86_64}-release.apk` (18,5 / 16,1 / 19,9 МБ) | `app/android/app/build.gradle.kts:21, 26`, `.github/workflows/mobile.yml:43-51` |
| iOS (мобильный) | проект подготовлен (имя приложения, плагины), бинарь не собирался — **сборка возможна только на macOS** | `app/build/ios/iphoneos/Runner.app` (путь сборки, см. §8) | `app/ios/Runner/Info.plist:9-10`, `.github/workflows/mobile.yml:53-73` |
| macOS | только код, бинари не собирались | — | там же |
| ОС «Аврора» | открытый вопрос, работ не найдено (вариант через Android APK — см. `docs/specs/09_roadmap.md` §4) | — | `docs/HANDOFF.md:294` |

Кроссплатформенность обеспечивается единым деревом Flutter-кода и условными импортами `app/lib/platform/*` (io/web-двойники), а не отдельными сборками — `docs/HANDOFF.md:39-54`. Мобильные сборки используют тот же код: отличаются только платформенный слой (каталоги данных, выбор файла, сохранение отчётов, признак `isMobile`) и отсутствие локального конвертера — §7, §12, §13.

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
| Android SDK (локальная установка) | `cmdline-tools` (`latest`), `platform-tools`, `platforms;android-35`, `build-tools;35.0.0` | `.tools\android-sdk` (в git не входит — `/.tools/` в `.gitignore:8`) | каталоги присутствуют в дереве |
| Android SDK, записанный в проекте | `sdk.dir=C:\Users\vkara\Desktop\DSH\vibe cam\.tools\android-sdk` (после первой сборки APK Flutter перезаписал файл) | `app/android/local.properties:1` (файл генерируемый и не коммитится — `app/android/.gitignore:6`) | фактически использован локальный SDK `.tools\android-sdk`; `%LOCALAPPDATA%\Android\sdk` существует, но не использовался |
| Java / сборочная обвязка Android | Java 17 (`sourceCompatibility`/`targetCompatibility`), AGP 9.1.0, Kotlin 2.4.0 | `app/android/app/build.gradle.kts:12-15`, `app/android/settings.gradle.kts:22-23`; в CI — Temurin 17 (`.github/workflows/mobile.yml:26-29`) | — |
| Мобильные плагины Flutter | `file_selector` 1.1.0 (платформенные: `file_selector_android` 0.5.2+10, `file_selector_ios` 0.5.3+6), `path_provider` 2.1.6 (`path_provider_android` 2.3.1, `path_provider_foundation` 2.5.1) | `app/pubspec.yaml:14-24`, `app/pubspec.lock` | транзитивные FFI-плагины `jni`/`jni_flutter` 1.0.3, `jni_util` 1.0.0 (`pubspec.lock:171-194`) |
| Пин `path_provider_foundation` | ровно `2.5.1` (не `^`) | `app/pubspec.yaml:19-24` (причина записана комментарием) | 2.6.0 переходит на `objective_c` с build-hook, который не компилируется из-за **пробела в пути к Flutter SDK** (`.tools\flutter-src\flutter`) и ломает `flutter test`/сборки; пин можно снять при пути без пробелов |
| Движки конвертера | Inkscape + Ghostscript 10.07.1 | `cam_pipeline\inkscape_engine`, `cam_pipeline\ghostscript_engine` | `docs/HANDOFF.md:175` |
| Внешние pub.dev-зависимости | `file_selector` и `path_provider` добавлены для мобильных сборок (ранее внешних зависимостей не было) | `app/pubspec.yaml:14-26`, `app/pubspec.lock` | pub.dev в среде разработки недоступен: версии берутся из зафиксированного `pubspec.lock` |

Версии Dart не совпадают: SDK для домена — 3.13.3, встроенный в Flutter — 3.13.2 (`app/pubspec.yaml:8` требует `^3.13.2`). При прогоне домена вручную используется `.tools\dart-sdk` (`README.md:39-45`).

**Восстановление окружения на новой машине** (по `docs/HANDOFF.md:164-189`): быстрый вариант — скопировать каталог целиком (без `app/build`, `app/.dart_tool`, `services/*/data`, `*.db`); чистый вариант — `git clone`, затем Dart SDK в `.tools/dart-sdk`, Flutter stable в `.tools/flutter-src`, `flutter pub get` в `app/`, Python-venv с `pip install -r services/{converter,auth,payments,license}/requirements.txt`, движки Inkscape/Ghostscript (пути — через `PP_INKSCAPE`/`PP_GHOSTSCRIPT`) и отдельный Flutter Linux SDK в WSL.

## 3. Сборка Windows

1. Убедиться, что доступен Flutter из `.tools` (или из PATH): `.tools\flutter-src\flutter\bin\flutter.bat --version` — каталог содержит `flutter.bat`, `flutter`, `flutter-dev.bat` (`ls .tools/flutter-src/flutter/bin`).
2. Из каталога `app`: `flutter pub get` — подтягивает `prepress_core` по path-зависимости и мобильные плагины (`app/pubspec.yaml:25-26`, `README.md:50-54`).
3. Проверка перед сборкой: `flutter analyze` (ожидается 0 ошибок) и `flutter test` (`README.md:51-53`).
4. Сборка: `flutter build windows --release` (та же команда используется в CI — `.github/workflows/release.yml:29-30`).
5. Результат: `app\build\windows\x64\runner\Release\` — в дереве присутствуют `prepress_planner.exe` (≈91 КБ), `flutter_windows.dll` (≈21 МБ), `data\`, `native_assets.json`, а также рабочие папки `projects\` и `state\`.
6. Артефакт в CI выгружается из `app/build/windows/x64/runner/Release/` (`.github/workflows/release.yml:31-34`).

Пути с пробелами (`...\Desktop\DSH\vibe cam`) в командах Flutter проблем не создают, но для скриптов WSL/scp такие пути не годятся (см. §13); отдельно они «аукаются» при обновлении плагинов (пин `path_provider_foundation`, §2).

### 3.1 Состав Windows-сборки

| Файл/каталог | Что это | Ссылка |
|---|---|---|
| `prepress_planner.exe` | исполняемый файл (имя задано `BINARY_NAME`) | `app/windows/CMakeLists.txt:7`, артефакт в дереве |
| `flutter_windows.dll` | движок Flutter для Windows | артефакт в дереве; `app/windows/flutter/ephemeral/flutter_windows.dll` |
| `data/` | ресурсы сборки: `app.so`, `icudtl.dat`, `flutter_assets/`, включая `flutter_assets/assets/fonts/DejaVuSans.ttf` (шрифт PDF) | `app/pubspec.yaml:32-38`; состав каталога проверен в дереве |
| `native_assets.json` | служебный манифест сборки | артефакт в дереве |
| `projects/`, `state/` | рабочие каталоги (появляются при работе приложения); на мобильных их заменяют каталоги внутри песочницы приложения (§12) | `app/lib/main.dart:44-49, 78-79` |
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
3. Пометка для PDF: кириллический шрифт `assets/fonts/DejaVuSans.ttf` грузится через `rootBundle`, поэтому он попадает в web-сборку как asset (`app/pubspec.yaml:32-38`, `reports_screen.dart:122-133`).
4. Упаковка бандла развёртывания (из корня репозитория): `powershell -ExecutionPolicy Bypass -File deploy\build_bundle.ps1` (Linux/macOS — `bash deploy/build_bundle.sh`). Скрипт проверяет наличие `app\build\web\index.html`, копирует статику в `deploy/web`, пакует `services/{converter,auth,payments}` и создаёт `pp-new-server-stack.tar.gz` (`deploy/build_bundle.ps1:8-35`, `deploy/README.md:22-34`).
5. Развёртывание на сервере: `scp pp-new-server-stack.tar.gz root@<IP>:/`, распаковка в `/stack`, `cd stack/deploy && bash install_new_server.sh` (`deploy/README.md:36-48`).
6. Раздача: nginx в контейнере `web` (`8081:80`) отдаёт статику из `./web` и проксирует `/auth`, `/payments`, `/convert`, `/data`, `/healthz` на имена сервисов (`deploy/docker-compose.yml:82-93`, `deploy/nginx/pp-web.conf:11-38`), `client_max_body_size 64m` (`pp-web.conf:40`).
7. Локально каталог `deploy/web` **отсутствует** — он создаётся только скриптом сборки бандла.

## 7. Сборка Android

Мобильная сборка использует тот же код `app/lib`, что desktop и web; отличаются только платформенный слой (§12, §13) и наличие Android-проекта `app/android/` (создан шаблоном `flutter create --platforms=android .`; каталог добавлен в репозиторий 2026-09-07).

1. **Android SDK.** Ставится локально в `.tools\android-sdk`: `cmdline-tools` (`latest`, оттуда `sdkmanager`), `platform-tools`, `platforms;android-35/36`, `build-tools;35.0.0/36.0.0`, а также NDK и CMake (доустановлены Gradle при первой сборке — в логе сборки `Installing NDK (Side by side)`, `Install CMake 3.22.1 in …\.tools\android-sdk\cmake\3.22.1`); сам `.tools/` в git не входит (`.gitignore:8`). Проверено на сборке APK: Flutter перезаписал `app/android/local.properties` на `sdk.dir=C:\Users\vkara\Desktop\DSH\vibe cam\.tools\android-sdk`, и это единственный SDK, который использовался (`%LOCALAPPDATA%\Android\sdk` существует, но к сборке не привлекался).
2. **Указать SDK Flutter'у:** `flutter config --android-sdk <путь>` (значение сохраняется в конфиге Flutter) либо переменная окружения `ANDROID_HOME`. В проверенной среде `ANDROID_HOME`/`ANDROID_SDK_ROOT` не заданы, а Flutter дополнительно читает `sdk.dir` из `app/android/local.properties`.
3. **Java 17.** Требование записано в `app/android/app/build.gradle.kts:12-15` (`sourceCompatibility`/`targetCompatibility` = `JavaVersion.VERSION_17`) и `:45-49` (`jvmTarget`); в CI ставится Temurin 17 (`.github/workflows/mobile.yml:26-29`).
4. **Первая сборка скачивает зависимости Gradle** (AGP 9.1.0, Kotlin 2.4.0 — `app/android/settings.gradle.kts:22-23`, обёртка — `app/android/gradle/wrapper/gradle-wrapper.properties`) — нужен доступ в интернет.
5. **Команды** (из каталога `app`): `flutter pub get` → `flutter analyze` → `flutter test` → `flutter build apk --release`. Те же шаги выполняет CI-джоб `android` (`.github/workflows/mobile.yml:34-45`).
6. **Результат (сборка выполнена 2026-09-07):** `app/build/app/outputs/flutter-apk/app-release.apk` — 53,0 МБ (55 584 636 байт), SHA-256 `dce604481ab9fc173bc4abe8ca66c6748b93f7b70e5e5e60903e40a233a4a3bf`; рядом `app-release.apk.sha1`. Команда `flutter build apk --release --split-per-abi` даёт три файла: `app-arm64-v8a-release.apk` (18,5 МБ), `app-armeabi-v7a-release.apk` (16,1 МБ), `app-x86_64-release.apk` (19,9 МБ). Копия универсального APK выложена на рабочий стол (`.dsh-tmp`-независимо, вне репозитория); сам `app/build/**` в git не попадает (`.gitignore:14`). Проверка содержимого: `aapt2 dump badging` → `package: name='ru.prepress.planner'`, `application-label:'Препресс-Планер'`, `uses-permission: android.permission.INTERNET`, `targetSdkVersion:'36'`, `versionName='1.0.0'`. Тот же путь ожидает и CI-артефакт (`.github/workflows/mobile.yml:50`, `if-no-files-found: error`).
7. **Подпись release-сборки.** Сейчас используется **debug-подпись**: `signingConfig = signingConfigs.getByName("debug")` (`app/android/app/build.gradle.kts:36-42`, TODO шаблона). Такой APK годится для ручной установки и тестов, но **не для Google Play**. Для публикации нужны свой keystore, файл `key.properties` и `signingConfigs.release` (шаблон ссылается на `https://flutter.dev/to/reference-keystore`); `key.properties`, `*.keystore`, `*.jks` уже вне git (`app/android/.gitignore:10-14`). Команда для подписанного релиза остаётся `flutter build apk --release` (при наличии конфигурации подписи); альтернативы — `--split-per-abi` (проверено: три APK, см. п. 6) / `appbundle` (`flutter build appbundle` даёт AAB для Play — не проверялось, в CI используется только APK).
8. **Идентификаторы приложения:** `applicationId = "ru.prepress.planner"` (`app/android/app/build.gradle.kts:21`), при этом `namespace` намеренно оставлен шаблонным `com.example.prepress_planner` (`:8`): смена namespace сломала бы `android:name=".MainActivity"` в манифесте (комментарий `:17-20`). `versionCode`/`versionName` берутся из `pubspec.yaml:5` (`version: 1.0.0+1`) — `build.gradle.kts:32-33`.
9. **`minSdk` = 24** (`build.gradle.kts:24-26`: `minSdk = flutter.minSdkVersion` с комментарием, что это требование `file_selector_android`; `path_provider` требует меньшего). `compileSdk`/`targetSdk` — из Flutter (`:9, 27`).
10. **Имя, разрешения, сеть:** `android:label="Препресс-Планер"`, `uses-permission INTERNET`, `android:networkSecurityConfig="@xml/network_security_config"` — `app/android/app/src/main/AndroidManifest.xml:3, 5, 8`. Cleartext (http) разрешён **только** для `193.233.193.12` и `localhost` (`app/android/app/src/main/res/xml/network_security_config.xml:12-16`); глобальный `usesCleartextTraffic` не включался, в файле есть TODO убрать конфиг после перехода серверов на HTTPS (`:2-11`). Смена адреса/домена сервера требует правки этого списка — иначе Android 9+ заблокирует http.
11. **Анализатор:** каталог `android/**` исключён из `flutter analyze` (`app/analysis_options.yaml:11`), т.е. Kotlin/Gradle-часть анализом Dart не покрывается.
12. **Проверки (2026-09-07):** `flutter analyze` — 0 ошибок (3 info про `dart:html`), `flutter test` — 36/36 (прогон после мобильных правок), `flutter build web` ✓, `flutter build windows --release` ✓, `flutter build apk --release` ✓ (артефакты — п. 6), `flutter build apk --release --split-per-abi` ✓.

## 8. Сборка iOS (только macOS)

Сборка iOS невозможна на Windows/Linux: нужны macOS и Xcode. Проект в дереве есть (`app/ios/`), **бинарь не собирался**; единственный доступный контур — CI-джоб `ios` на `macos-latest` (`.github/workflows/mobile.yml:53-73`).

1. **Проект:** `app/ios/Runner.xcodeproj`, `app/ios/Runner.xcworkspace`, Swift-код `AppDelegate.swift`/`SceneDelegate.swift`. Отображаемое имя — `CFBundleDisplayName` = «Препресс-Планер» (`app/ios/Runner/Info.plist:9-10`), внутреннее `CFBundleName` оставлено `prepress_planner` (`:17-18`).
2. **Плагины:** `Podfile` в дереве **отсутствует** — Flutter 3.47 подключает плагины через Swift Package Manager; сгенерированный SPM-пакет лежит в `app/ios/Flutter/ephemeral/Packages/FlutterGeneratedPluginSwiftPackage/`, регистрация — `app/ios/Runner/GeneratedPluginRegistrant.m:9-25` (`FileSelectorPlugin`, `PathProviderPlugin`). Дополнительных требований (разрешений, подов, правок Xcode-проекта) у этих плагинов нет; шага `pod install` в CI тоже нет.
3. **Сборка без подписи (проверочная):** `flutter build ios --release --no-codesign` из каталога `app` — тот же шаг в CI (`.github/workflows/mobile.yml:62-67`); результат — `app/build/ios/iphoneos/Runner.app` (путь артефакта CI, `mobile.yml:72`).
4. **Публикация:** нужны аккаунт разработчика Apple, сертификат и provisioning-профиль (либо автоматическая подпись в Xcode); для App Store дополнительно требуется архив и загрузка через Xcode/Transporter. Покупка Pro внутри приложения сейчас — заглушка (`docs/VERIFICATION.md:27`, `docs/specs/09_roadmap.md` §3.1): политика Apple требует StoreKit/IAP и не допускает внешние платежи.
5. **Сеть (важно):** адреса сервисов зашиты как `http://193.233.193.12:8120-8122` (`converter_api.dart:59`, `account_client.dart:202, 327`), а на iOS http по умолчанию блокируется App Transport Security. **Добавлено 2026-09-07:** в `app/ios/Runner/Info.plist` есть `NSAppTransportSecurity` → `NSExceptionDomains` с исключением `NSExceptionAllowsInsecureHTTPLoads` для `193.233.193.12` и `localhost` (по аналогии с Android-конфигом cleartext; в файле TODO убрать после перехода на HTTPS). Проверка на устройстве/симуляторе по-прежнему **требуется**: если ATS всё же блокирует IP-литерал, потребуется временно `NSAllowsArbitraryLoads` (или домен с TLS).
6. **`path_provider_foundation` запинен на 2.5.1** (`app/pubspec.yaml:19-24`) — на iOS это даёт тот же каталог `Documents` обычным плагином (SPM/CocoaPods), без build-hook `objective_c`; причина пина — пробел в пути к Flutter SDK (§2).
7. Сборка и запуск на реальном устройстве, а также работа мобильного выбора файла на iOS **не проверялись**.

## 9. CI мобильных сборок (`mobile.yml`)

`.github/workflows/mobile.yml` — отдельный workflow (в git пока не закоммичен) с двумя независимыми джобами:

| Джоб | Раннер | Шаги | Артефакт |
|---|---|---|---|
| `android` | `ubuntu-latest` | Java 17 (Temurin), Flutter `stable` с кэшем, `flutter pub get` → `flutter analyze` → `flutter test` → `flutter build apk --release` (`.github/workflows/mobile.yml:26-45`) | `prepress-planner-android-apk` = `app/build/app/outputs/flutter-apk/app-release.apk` (`:46-51`, `if-no-files-found: error`) |
| `ios` | `macos-latest` | Flutter `stable` с кэшем, `flutter pub get`, `flutter build ios --release --no-codesign` (`:57-67`) | `prepress-planner-ios-unsigned` = `app/build/ios/iphoneos/Runner.app` (`:68-73`) |

Триггеры: push в `master`/`main` при изменениях в `app/**` или в самом workflow, pull_request по `app/**`, ручной запуск (`mobile.yml:9-18`). В iOS-джобе нет шагов `analyze`/`test` (только сборка) — по замыслу они покрыты Android-джобом. Подпись не выполняется ни для APK (debug-ключ из шаблона, см. §7.7), ни для iOS (`--no-codesign`): артефакты пригодны для проверки, но не для публикации.

Прогон workflow **не подтверждён**: по документации проекта в GitHub Actions не запускался ни один workflow (`README.md:78`, `docs/HANDOFF.md:67, 244`; §15.1). Для `mobile.yml` это тем более **требует проверки** — в частности, не подтверждены доступность `file_selector_android`/`path_provider_android` в чистом раннере и отсутствие проблемы с build-hook `objective_c` на macOS-раннере (там путь к Flutter SDK без пробелов).

## 10. Запуск готовых сборок

| Сборка | Как запустить | Что должно лежать рядом |
|---|---|---|
| Windows | двойной клик по `app\build\windows\x64\runner\Release\prepress_planner.exe` | `flutter_windows.dll`, `data\`, каталоги `projects\`, `state\` (создаются при работе) |
| Linux (WSL) | ярлык «Препресс-Планер (Linux).cmd» либо `wsl.exe -d Ubuntu -u dev --cd <bundle> -e <bundle>/prepress_planner` | весь каталог `bundle` (`lib/`, `data/`) |
| Web | открыть `http://193.233.193.12:8081` в браузере | статика в `deploy/web` на сервере + запущенные converter/auth/payments |
| Android | установить `app-release.apk` на устройство и открыть (подробно — `РУКОВОДСТВО_ПОЛЬЗОВАТЕЛЯ.md`, раздел про мобильные версии); для отладки — `flutter run --release` с подключённым устройством/эмулятором | ничего: APK самодостаточен; интернет нужен для AI/CDR/EPS, аккаунта и подписки |

Рабочие каталоги `projects/` и `state/` создаются рядом с запущенным приложением/рабочим каталогом (`app/lib/main.dart:44-49, 78-79`); на web их заменяет `localStorage`, на Android/iOS — каталог приложения (§12).

## 11. Переменные окружения по платформам

**Клиент (приложение):**

| Переменная | Desktop | Web | Android/iOS | Значение по умолчанию | Ссылка |
|---|---|---|---|---|---|
| `PP_CONVERTER_URL` | читается при старте | не читается | формально читается (`env_io.dart`), но задать её в мобильной сборке нельзя → работает значение по умолчанию | `http://193.233.193.12:8120` | `converter_api.dart:56-59`, `converter_server.dart:21-22` |
| `PP_AUTH_URL` | читается | не читается | то же (дефолт) | `http://193.233.193.12:8121` | `account_client.dart:201-202` |
| `PP_PAYMENTS_URL` | читается | не читается | то же (дефолт) | `http://193.233.193.12:8122` | `account_client.dart:326-327` |
| `PP_CONVERTER_PYTHON` | путь к venv-python для локального uvicorn | нет | не применяется: дочерний процесс uvicorn на Android/iOS не запускается (§13.1, п. 15) | авто-поиск `cam_pipeline\venv\Scripts\python.exe` | `server_launch_io.dart:25-35, 105-120` |
| `USERPROFILE` | стартовый каталог диалога выбора файла | нет | не применяется: на мобильных путь не вводится, файл выбирается системным диалогом | каталог по умолчанию (`Directory.current`) | `files_io.dart:9-15, 84-93` |

На web переменных окружения нет вовсе: `envOrDefault` всегда возвращает `''`, поэтому адреса становятся относительными и работают через прокси nginx (`platform/env_web.dart:6`, `platform/env.dart:11-12`, `deploy/README.md:80-83`). На мобильных дефолтные адреса указывают на сервер по **http**, поэтому для Android добавлен конфиг cleartext (§7.10), а для iOS — исключение ATS для того же адреса и `localhost` (§8.5; проверка на устройстве — за заказчиком).

**Сервисы (deploy/docker-compose и локальный запуск):** `PP_DATA_DIR`, `PP_JOB_STORE`, `PP_JOB_TTL_HOURS`, `PP_MAX_MB`, `PP_INKSCAPE`, `PP_GHOSTSCRIPT` (converter); `PP_AUTH_SECRET` (обязателен), `PP_TOKEN_TTL`, `PP_RESET_TTL`, `PP_SMTP_*`, `PP_SMTP_SSL` (auth); `PP_AUTH_URL` (обязателен), `PP_PUBLIC_BASE` (payments) — см. `docs/specs/04_services_api.md`, §2–4, и `deploy/.env.example`.

## 12. Где хранятся данные

**На Android/iOS** рабочий каталог процесса недоступен для записи, поэтому состояние, проекты и отчёты живут в приватном каталоге приложения: `getApplicationDocumentsDirectory()` + подкаталог `PrepressPlanner` (`app/lib/platform/app_dirs_io.dart:11-18, 20-31, 33-40`, обёртка — `app/lib/platform/app_dirs.dart:10, 13`). На desktop/web та же функция возвращает `null`, и пути остаются прежними относительными (`state`, `projects`) — поведение существующих сборок не меняется (`app_dirs_web.dart:5-7`, `app/lib/main.dart:44-49`). По данным правок это `/data/user/0/ru.prepress.planner/app_flutter/PrepressPlanner` на Android и `Documents/PrepressPlanner` внутри песочницы приложения на iOS; на реальном устройстве путь **не проверялся**.

| Данные | Desktop | Web | Android/iOS | Ссылка |
|---|---|---|---|---|
| Проекты | `<каталог запуска>/projects/<имя>.json` (JSON v2) | `localStorage`: `pp_prepress_planner.projects/<имя>.json` | `<каталог приложения>/PrepressPlanner/projects/<имя>.json` | `main.dart:78-79`, `project.dart:292-317`, `platform/json_store_io.dart:6-46`, `platform/json_store_web.dart:10-27` |
| Подписка (кэш) | `state/entitlement.json` | `pp_prepress_planner.state/entitlement.json` | `<каталог приложения>/PrepressPlanner/state/entitlement.json` | `main.dart:44-45, 54-55`, `entitlement_store.dart:15-17` |
| Сессия аккаунта (токен) | `state/session.json` | `pp_prepress_planner.state/session.json` | `<каталог приложения>/PrepressPlanner/state/session.json` | `account_client.dart:87-109` |
| Идентификатор устройства | `state/machine_id.txt` | `pp_prepress_planner.state/machine_id.txt` | `<каталог приложения>/PrepressPlanner/state/machine_id.txt` | `license_client.dart:104-114` |
| Каталог материалов | `state/materials.json` | `localStorage`-ключ того же вида | `<каталог приложения>/PrepressPlanner/state/materials.json` | `material_library.dart:23, 162-179` |
| Отчёты PDF/XLSX/DXF | файлы в каталоге `projects` (путь показывается в статусе) | скачивание браузером | `<каталог приложения>/PrepressPlanner/reports/` (подпись в UI: «Экспорт: файлы сохраняются в каталог приложения (подкаталог reports)») | `reports_screen.dart:111-122, 158-163, 214, 242, 276`, `platform/save_out_io.dart:11-23`, `platform/save_out_web.dart:8-9` |
| Задача конвертации | `PP_DATA_DIR/out/<job_id>/…`, при `file` — `jobs/<id>.json` | — (серверная сторона) | — (серверная сторона) | `services/converter/converter_app/main.py:53-77, 143`, `jobs.py:154-177` |
| Аккаунты/заказы | `auth.db`, `payments.db` в томах `auth-data`, `payments-data` | — | — | `deploy/docker-compose.yml:52-53, 71-72` |

Дополнительно: на **desktop** функция `saveFileForUser` пишет в `%USERPROFILE%\Downloads` (`platform/files_io.dart:97-104`), но отчётами она не используется (их пишет `saveReport`); на **Android/iOS** та же функция тоже переопределена на каталог приложения (`files_io.dart:95-104`) — внешнего `Downloads`/домашнего каталога там нет, на web — скачивание (`platform/save_out_web.dart:8-9`).

Итог для пользователя: на мобильных данные и отчёты лежат **внутри приложения** и в файловом менеджере не видны; вынос отчётов «наружу» (Downloads/MediaStore/share-sheet) и импорт из внешнего хранилища — отдельная задача (см. `docs/specs/09_roadmap.md`).

## 13. Особенности и «грабли»

1. **Пути с пробелами.** Рабочая копия — `C:\Users\vkara\Desktop\DSH\vibe cam`. Для сборочных команд Flutter это нормально, но для WSL/scp/ssh-скриптов требуется путь без пробелов: временные скрипты складываются в `C:\Users\vkara\.dsh-tmp` (`docs/HANDOFF.md:176, 251-253`).
2. **Аргументы ssh с кавычками ломаются** — сложные команды оформляются bash-скриптом в каталог без пробелов, заливаются по `scp` и запускаются на сервере (`docs/HANDOFF.md:251-253`).
3. **Пайпы нативных команд под песочницей DSH (Windows) дают EPERM** — вывод нативных программ (`git`, `ssh`, WSL и т.п.) нельзя захватывать конвейером и `2>&1`; запускать без захвата вывода или через файловый stdio (`docs/HANDOFF.md:248-250`).
4. **git «dubious ownership»** — добавлять `-c safe.directory` (или `-c safe.directory='*'`) (`docs/HANDOFF.md:255`).
5. **Только UTF-8.** PowerShell `Set-Content` портит кириллицу — файлы писать редактором/write-инструментом (`docs/HANDOFF.md:256-257`).
6. **Инструменты не в PATH, а в `.tools`** — Dart берётся как `.tools\dart-sdk\bin\dart.exe`, Flutter — как `.tools\flutter-src\flutter\bin\flutter.bat`; при отсутствии публикации в PATH команды `dart`/`flutter` могут не находиться (`README.md:39-45`, `.tools/dart-sdk/version`).
7. **Flutter Linux — отдельный SDK в WSL**; Windows-пути `/mnt/c/...` для сборки Linux не используются — проект собирается из `/home/dev/pp` (`docs/HANDOFF.md:172-173`).
8. **pub.dev в среде разработки недоступен** — раньше проект вообще не имел внешних зависимостей (только Flutter SDK и локальный `prepress_core`); теперь для мобильных сборок добавлены `file_selector` и `path_provider` (`app/pubspec.yaml:14-26`), а версии зафиксированы в `app/pubspec.lock`. Это значит, что мобильные сборки менее автономны: без доступа в pub.dev новая версия плагина не подтянется, а ранее разрешённые версии берутся из `app/pubspec.lock`.
9. **Локальный конвертер требует venv-python и каталога `services/converter`** рядом с деревом; путь ищется вверх до 12 уровней от exe и от текущего каталога (`server_launch_io.dart:90-131`). Если не найдено — сообщение с подсказкой «Запустите сервер вручную: uvicorn converter_app.main:app --port 8120» (`server_launch_io.dart:25-35`).
10. **Мусор не коммитить:** `app/projects/`, `app/state/`, `services/*/data/`, `*.db`, `__pycache__`, `.dart_tool`, `build/`, `.tools/`, `cam_pipeline/`, `cam_material/`, `*.tar.gz`, реальные `.env` (`docs/HANDOFF.md:270-273`). Для мобильных добавляется: `app/android/local.properties`, `key.properties`, `*.keystore`/`*.jks` (уже в `app/android/.gitignore:6, 10-14`), `app/ios/Flutter/ephemeral/` и `app/ios/.symlinks/` (`app/ios/.gitignore:14, 22`), а также локальный Android SDK (`.tools/android-sdk`, покрыт `/.tools/`).
11. **Web-сборка требует прокси** — относительные адреса (`/auth`, `/payments`, `/convert`, `/data`) работают только за nginx единого origin (`README.md:91`, `deploy/nginx/pp-web.conf:11-38`).
12. **PowerShell/DSH:** `flutter test` и другие нативные команды запускать без конвейеров; вывод длинных сборок удобнее направлять в файл.

### 13.1 Особенности мобильных версий (Android/iOS)

13. **Данные — в приватной песочнице приложения.** На Android/iOS каталоги `state`, `projects` и `reports` создаются внутри каталога приложения (§12), а не рядом с исполняемым файлом; в файловом менеджере они **не видны**. Вынос отчётов «наружу» (Downloads/MediaStore/share-sheet) — отдельная задача, в текущей версии не реализован.
14. **Отчёты не попадают в «Загрузки».** `saveReport` на мобильных игнорирует каталог из UI и пишет в `<каталог приложения>/PrepressPlanner/reports` (`platform/save_out_io.dart:11-23`); в UI это подписано «Экспорт: файлы сохраняются в каталог приложения (подкаталог reports)», а статус — «PDF сохранён в каталог приложения: …» (`reports_screen.dart:158-163, 214, 242, 276`).
15. **Нет локального конвертера.** Дочерний процесс `uvicorn` на мобильных не запускается, поэтому `_serverIsLocal` всегда `false` и кнопка показывает только «Проверить сервер» (плюс «Сервер работает» при успешной пробе) — `geometry_screen.dart:739-767, 769-773`. Форматы AI/CDR/EPS на мобильных возможны **только** через сервер.
16. **Импорт файла — системный выбор.** Поля пути и кнопки «Обзор» на мобильных нет (как и на web): показывается текст «Файл: DXF/SVG/PDF/AI/CDR/EPS — выберите файл кнопкой «Импорт файла»…» и кнопка «Импорт файла» (`geometry_screen.dart:206, 240-255, 562-566`), файл читается через `file_selector.openFile` (`platform/files_io.dart:60-93`). Фильтры намеренно разные: на Android заданы и расширения, и MIME (иначе `.ai/.cdr/.eps/.dxf` системный провайдер отдаёт как `application/octet-stream` и они были бы скрыты), на iOS — UTI и корневой `public.data` (системных UTI для CDR/DXF нет) — `platform/files_io.dart:54-79`.
17. **Cleartext только для двух хостов.** Android 9+ блокирует http, поэтому добавлен `network_security_config.xml` с исключением для `193.233.193.12` и `localhost` (§7.10); при смене адреса сервера или переходе на домен файл нужно править. На iOS добавлено аналогичное исключение ATS для тех же хостов (`app/ios/Runner/Info.plist`, §8.5); проверка на устройстве — за заказчиком.
18. **Пробел в пути к Flutter SDK — источник «граблей» при обновлении плагинов.** Из-за него пришлось пинить `path_provider_foundation: 2.5.1` (§2); при переносе рабочей копии в путь без пробелов пин можно снять.
19. **Desktop-сборки затрагиваются косвенно.** `path_provider`/`file_selector` регистрируются и на desktop: `app/windows/flutter/generated_plugins.cmake:5-11` и `app/linux/flutter/generated_plugins.cmake:5-11` получили `file_selector_windows`/`file_selector_linux` и FFI-плагин `jni` (транзитивная зависимость мобильных плагинов, `app/pubspec.lock:171-194`). Пересборка Windows/Linux после этого заявлена успешной, но в этой сессии не выполнялась — **требует проверки**.

## 14. Чек-лист «собрать и проверить»

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
11. **Мобильные (Android):** `flutter config --android-sdk <путь>` (или `ANDROID_HOME`), `flutter doctor` — раздел Android toolchain без ошибок; затем `flutter build apk --release` и проверка `app/build/app/outputs/flutter-apk/app-release.apk`. **Выполнено 2026-09-07** (APK и варианты по ABI — §7.6); установка на устройство (`flutter devices` → `flutter run --release`) не выполнялась и остаётся за заказчиком.
12. **Мобильные (iOS, только macOS):** `flutter build ios --release --no-codesign` → `app/build/ios/iphoneos/Runner.app`. Проверить, что SPM-пакет собрался (`app/ios/Flutter/ephemeral/Packages/FlutterGeneratedPluginSwiftPackage/`) и что `pod install` не требуется. На Windows/Linux шаг неприменим.

## 15. Известные проблемы

1. **CI на GitHub ни разу не прогонялся** — репозиторий был запушен, но workflows `ci.yml`/`release.yml` не запускались (`README.md:78`, `docs/HANDOFF.md:67, 244`). В сервис-джобе учтён skipif-тест Inkscape (`docs/HANDOFF.md:262-263`). Добавленный `mobile.yml` (§9) не прогонялся тем более.
2. **`deploy/web` в репозитории нет** — каталог появляется только после `build_bundle.ps1`; `docker compose up` без предварительной web-сборки раздаст пустой каталог (`deploy/build_bundle.ps1:10-13, 19`).
3. **Linux-сборка живёт только в WSL** по пути `/home/dev/pp/...`; в Windows-дереве каталог `app/build/linux` отсутствует, ярлык без WSL не работает (`C:\Users\vkara\Desktop\Препресс-Планер (Linux).cmd:9-10`).
4. **macOS/iOS/Аврора не собраны** — код кроссплатформенный, но бинарей нет; для iOS дополнительно нужны StoreKit/IAP и аккаунт разработчика (`docs/HANDOFF.md:292-294`). После правок 2026-09-07 iOS-проект подготовлен (имя приложения, плагины через SPM, §8), а Android-проект добавлен (§7), однако **сборка iOS возможна только на macOS**, а APK в рабочем дереве отсутствует — оба артефакта **требуют проверки**.
5. **Расхождение версий Dart** (3.13.3 в `.tools` против 3.13.2 во Flutter) может давать разное поведение анализа/компиляции домена при прямых вызовах `.tools\dart-sdk`.
6. **`app/build`, `app/projects`, `app/state` не в git** — при чистом клоне проекта/сборок нет, требуется `flutter pub get` и повторная сборка (`docs/HANDOFF.md:166-189, 270-273`).
7. **Тяжёлые операции на web идут в главном потоке** (изолятов в браузере нет) — лечение/распознавание большого файла может «подвешивать» интерфейс (`platform/isolates_web.dart:1-5`).
8. **Сервер работает по http, TLS нет** — дефолтные адреса клиента указывают на `http://193.233.193.12:8120-8122`, трафик не шифруется (`docs/specs/04_services_api.md` §8; `SECURITY.md` К-3). Перевод десктопа на единый origin `:8081` запланирован в `SECURITY.md`, фаза 1. Для Android дополнительно закреплено конфигом cleartext (§7.10), для iOS — исключением ATS (§8.5); переход на HTTPS потребует удалить оба исключения.
9. **Мобильные версии не тестировались на реальном устройстве.** APK собран (53,0 МБ + варианты по ABI, §7.6), но не устанавливался и не запускался; iOS-сборка не выполнялась (нужен macOS). Проверено: `flutter analyze` — 0 ошибок, `flutter test` — 36/36, сборки web/Windows — успешны. Поведение системного выбора файла, песочницы и сетевых запросов на Android/iOS — **требует проверки на устройстве**.
10. **Отчёты и состояние на мобильных недоступны пользователю извне.** Файлы лежат в приватной песочнице (§12), «поделиться»/сохранение в «Загрузки» не реализовано — вынос отчётов наружу требует отдельной задачи (share-sheet/MediaStore).
11. **Release-подпись APK — debug-ключ.** Для Google Play нужен собственный keystore и `signingConfigs.release` (§7.7), иначе магазин такую сборку не примет; для iOS нужен сертификат/профиль Apple (§8.4).
12. **Расхождение путей Android SDK — устранено.** `app/android/local.properties` при сборке перезаписан Flutter'ом на `.tools\android-sdk` (фактически использованный SDK — он же, §7.1). На чистой машине потребуется заново выполнить `flutter config --android-sdk`.
