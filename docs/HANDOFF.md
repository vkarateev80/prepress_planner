# HANDOFF — переезд «Препресс-Планер» на другой компьютер / в новую сессию

> **Для кого:** новая сессия агента (или разработчик) на другом компьютере.
> Этот файл — полный слепок контекста проекта: что сделано, где лежит,
> как проверить, что переносить, какие грабли окружения были на старой машине.
> Прочитайте его целиком перед любой работой.

- **Дата подготовки:** переезд (снимок состояния на коммит `35a5711`, ветка `master`, 25 коммитов, дерево чистое).
- **Проект:** «Препресс-Планер» — мультиплатформенное (iOS · Windows · macOS · Linux) приложение
  препресс-планирования расходных материалов и экономико-технического обоснования (ТЭО) тиражей этикеток.
- **Парадигма (утверждена заказчиком):** планирование расходных материалов препресса + ТЭО.
  УФ-маска и генерация УП/G-кода **намеренно удалены** из новой версии (остались только в легаси-эталоне).
- **Монетизация (утверждена):** Free → Pro по подписке, триал 15 дней; статьи затрат —
  материал ₽/м², сортамент, машиночасы, скорость печати, переналадка, рабочее время.

---

## 1. Карта репозитория

```
<корень>/                      = git-репозиторий (ветка master)
├── packages/core/             ЧИСТЫЙ Dart-домен (без Flutter, без pub.dev): ВСЯ математика
│   ├── lib/prepress_core.dart — баррел; под-папки: model, geom, parser, healer,
│   │                           optimizer, calculator, manufacturability, economics, reports
│   ├── test/*_test.dart       16 исполняемых тест-скриптов (void main(); не пакет test)
│   ├── tool/test_utils.dart   хелперы (expect/expectEq/expectNear/ok)
│   └── tool/e2e.dart          сквозной сценарий (эталонные числа)
├── app/                       Flutter-приложение (UI «Препресс-Планер»)
│   ├── lib/main.dart          вход; LicenseController со старта (триал 15 дн.)
│   ├── lib/src/               projects (store v2), screens (5 вкладок), widgets
│   └── lib/license/           license_client, entitlement_store (+FeatureGate/TrialTimer),
│                              license_controller (ChangeNotifier), paywall_screen
├── services/converter/        FastAPI: AI/CDR/EPS → SVG/PDF (пакет converter_app)
├── services/license/          FastAPI: триал/ключи/подписки/webhooks (пакет license_app)
├── scripts/run_domain_tests.{ps1,sh}  цикл по тестам домена
├── .github/workflows/{ci,release}.yml  CI (скачивает SDK на раннере — путей нет)
├── fixtures/                  эталонные файлы для тестов (в git, 11 МБ)
├── agents/00..14.md           контракты субагентов (история исполнения)
├── docs/VERIFICATION.md       приёмка §10 спеки фактическими выводами
└── docs/superpowers/{specs,plans}/  спека + план реализации
```

Легаси-эталон (НЕ в git, `.gitignore`): `cam_pipeline/`, `cam_material/` — исходный Python-код,
из которого портирован домен. Нужны только как оракул для сверки (shapely/ezdxf/PyMuPDF).

## 2. Статус проекта — ВСЁ ВЫПОЛНЕНО

| Фаза | Содержание | Статус |
|---|---|---|
| Ф0 | git, монорепо, спека, план, контракты 00–14, фикстуры | ✅ `2629ee9` |
| Ф1 | домен: геометрия, парсеры DXF/SVG/PDF/AI, лечение, массивы, расход+shape, технологичность | ✅ `60be4ab`…`bd3a211` |
| Ф2 | экономика/ТЭО + отчёты PDF/XLSX/DXF | ✅ `f6986fb`, `57d7bc6` |
| Ф3 | Flutter UI (MVP, 5 вкладок) | ✅ `7196c01` |
| Ф4 | конвертер + лицензии + подписка (триал 15 дн.) | ✅ `7840767`, `426cc41`, `68c566c` |
| Ф5 | CI, E2E, верификация | ✅ `bb1a7c3`, `6b274c0` |

**Цель (goal) закрыта.** Все критерии приёмки §10 спеки подтверждены живыми прогонами —
см. `docs/VERIFICATION.md` (заполнено фактическими выводами, не обещаниями).

### Эталонные числа (самопроверка после переезда)

- Расход 50×30/зазоры 3/Z96/CP3.175/N5000: **9×5, N=5040, оборотов=112, длина=34137.6 мм,
  отходы=26.18%, на этикетку=2032.0 мм²/шт** (раппорт 304.8 мм).
- ТЭО эталон: costPer1000=**704.88 ₽**, totalCost=3552.58, machineCost=2528.45, materialCost=1024.13,
  runTime≈0.0057 ч, загрузка смены 6.32%.
- E2E печатает всё это и завершается `E2E OK`, код выхода 0.

## 3. Как проверить на новом месте (5 команд)

```powershell
# 1. Домен (из корня; dart берётся из .tools или PATH)
powershell -File scripts/run_domain_tests.ps1        # → ALL PASS (16 files)

# 2. E2E (из packages/core)
& '<корень>\.tools\dart-sdk\bin\dart.exe' tool/e2e.dart   # → E2E OK

# 3. Flutter (из app) — нужен Flutter SDK
flutter analyze      # → No issues found!
flutter test         # → All tests passed! (15: 5 widget + 5 license + 5 license_ui)

# 4. Сервисы (из корня; python = venv или системный с нужными пакетами)
python -m pytest services/converter/tests services/license/tests -q   # → 17 passed

# 5. Греп-контроль (в core нет маски/G-кода)
grep -riE 'uv_mask|gcode|g_code|уф|уп' packages/core/lib   # → 0 (кроме «управляющие символы» в XML-комментарии)
```

## 4. Что переносить (варианты)

**В git только исходники + фикстуры (~25 МБ).** Машинно-зависимое — НЕ в git:

| Что | Где | Размер | Зачем |
|---|---|---|---|
| Dart SDK 3.13.3 | `.tools/dart-sdk` | часть .tools | домен |
| Flutter 3.47.2 stable | `.tools/flutter-src/flutter` | `.tools` всего ~5.9 ГБ | app |
| pub-cache | `.tools/pub-cache` | там же | flutter (path-зависимость на core) |
| Python venv 3.12.4 | `cam_pipeline/venv` | `cam_pipeline` всего ~2 ГБ | сервисы + оракул |
| Движки | `cam_pipeline/inkscape_engine` (работает), `cam_pipeline/ghostscript_engine` (в песочнице не стартует) | там же | конвертер |

**Вариант A (быстрый, рекомендуется):** скопировать ВСЮ папку целиком (~8 ГБ, можно без
`app/build`, `app/.dart_tool`, `services/converter/data`, `*.db` — они пересоздаются).
Всё работает сразу: пути в коде/скриптах совпадают (см. §6 про захардкоженные пути).

**Вариант B (чистый):** `git clone`/копия только исходников, затем восстановить инструменты:
1. Dart SDK 3.13.3 → в `.tools/dart-sdk` (или в PATH);
2. Flutter stable (версия в `app/pubspec.lock`/`flutter --version`; движок — см. §6),
   `flutter pub get` в `app/`;
3. Python 3.12 + `pip install -r services/converter/requirements.txt
   -r services/license/requirements.txt` + (для оракула) shapely ezdxf pymupdf;
4. Inkscape + Ghostscript в любое место, указать через env (см. §6) или положить по путям ниже.

## 5. Технические факты (для быстрого входа в код)

- **Домен:** только stdlib Dart. Тест-файл = скрипт: запуск `dart test/<file>.dart` из
  `packages/core`, код выхода 0 = успех. Баррел `prepress_core.dart` экспортирует всё.
- **UI:** `HomeShell` (5 вкладок; десктоп — NavigationRail, узкий — NavigationBar).
  `ProjectStore('projects')` — JSON v2 на диске. `LicenseController` в `main.dart`:
  первый запуск → MachineId + офлайн-триал 15 дней → кэш `state/entitlement.json`.
  Гейтинг: `FeatureGate.hasProAccess` (Pro **или активный триал**); Free = 1 проект +
  прямоугольный расчёт; вкладки Геометрия/ТЭО/Отчёты и «Перебор вариантов» — Pro
  (шторка «Доступно в Pro» → paywall). `purchase()` — заглушка до IAP.
- **Сервисы:** FastAPI, пакеты `converter_app`/`license_app` (имена НЕ `app` — коллизия).
  Лицензии: SQLite (наивный UTC `datetime.utcnow()`), HMAC offline-токены,
  грэйс 30 дней, триал 15 дней однократно. Конвертер: файловый stdio для движков,
  джобы в памяти, результат в `data/out/<uuid>/`.

## 6. Захардкоженные пути и env-переменные (важно для Варианта B)

| Файл | Что | Как обойти |
|---|---|---|
| `services/converter/converter_app/convert.py` | `INKSCAPE`, `GHOSTSCRIPT` — дефолты указывают на `cam_pipeline\...` старой машины | **уже читает env**: `PP_INKSCAPE`, `PP_GHOSTSCRIPT` |
| `scripts/run_domain_tests.ps1` | `.tools/dart-sdk/bin/dart.exe` | fallback на `dart` из PATH |
| `packages/core/README.md`, `app/README.md` | упоминания абсолютного пути | только документация |

Движок Flutter (для Варианта B без интернета к google): переменные
`FLUTTER_STORAGE_BASE_URL=http://storage.googleapis.com`,
`FLUTTER_PREBUILT_ENGINE_VERSION=a804b261645ef8c13eb3d5c44a5c2fb0340c5539`
(значение брать из `.tools/flutter-src/flutter/bin/cache/` старой машины).
Git на Windows: при «dubious ownership» добавлять `-c safe.directory='*'`.

## 7. Грабли окружения СТАРОЙ машины (не переносятся, но объясняют код)

- HTTPS к большинству хостов блокирован; рабочий канал — `http://storage.googleapis.com`.
- pub.dev недоступен → правило «только stdlib Dart» — **осознанное**, не лень.
- PowerShell-песочница DSH: нельзя пайпить вывод нативных команд и `2>&1`;
  git — только с `safe.directory`; Ghostscript не стартует (0xC0000142);
  движки конвертера запускаются с файловым stdio (пайпы EPERM).
- Файлы только UTF-8; PowerShell `Set-Content` портит кириллицу — писать через редактор/write.

## 8. Конвенции проекта (соблюдать и дальше)

- Коммиты: по одному на модуль/фазу, сообщения на русском вида «Ф4-12b: …»; git — журнал прогресса.
- Не коммитить артефакты: `services/converter/data/`, `*.db`, `__pycache__`, `.dart_tool`, `build/` (в .gitignore).
- Числа: координаты мм с 4 знаками, деньги 2 знака; тексты ошибок/UI — русские.
- В `packages/core` не появляются модули УФ-маски и G-кода (греп-контроль в CI/VERIFICATION).

## 9. Что дальше (открытые направления — выбирать заказчику)

1. **Импорт AI/CDR/EPS из приложения** — в `app/` нет HTTP-клиента к `services/converter`
   (сервис готов и протестирован).
2. **Windows-бинарь + запуск CI по-настоящему** — `.github/workflows` не прогонялись
   (репозиторий не запушен). Внимание: services-джоба CI требует Inkscape на раннере —
   `test_ai_to_svg_via_inkscape` скипается без него (skipif).
3. **Docker-развёртывание** сервисов (Dockerfile есть) + .env для license.
4. **iOS IAP (StoreKit)** — сейчас `purchase()`-заглушка; нужны macOS/Xcode + аккаунт разработчика.
5. Сервер лицензий реально не развёрнут (локально только pytest).

## 10. Ключевые документы

- Спека: `docs/superpowers/specs/2026-09-02-prepress-planner-design.md`
- План: `docs/superpowers/plans/2026-09-02-prepress-planner.md` (все задачи отмечены выполненными)
- Приёмка: `docs/VERIFICATION.md`
- Контракты агентов: `agents/00..14.md` (история; новые работы не обязаны им следовать)
- README корня: `README.md`
