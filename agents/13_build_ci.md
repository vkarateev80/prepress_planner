# Агент 13 — Сборка, релиз, CI (инфраструктура)

> **Актуализация 2026-09-07 (HEAD 448dcba):** статус — частично устарело.
> - Фактически собраны и задеплоены: **Windows** (`app\build\windows\x64\runner\Release\prepress_planner.exe`), **Linux** (через WSL, ярлык на рабочем столе), **Web** (`flutter build web` → nginx :8081, коммит `881cf72`). iOS/macOS-бинари не собирались (см. `docs/HANDOFF.md`).
> - Репозиторий запушен в GitHub `vkarateev80/prepress_planner` (ветка `master`, HEAD `448dcba`); `.github/workflows/ci.yml` и `release.yml` существуют, но **прогон GitHub Actions не подтверждён** — не утверждать обратное.
> - Состав стека изменился: Docker-образы собираются для converter/auth/payments/web (`deploy/`), а не «converter+license», как в матрице контракта.
> - `services/{converter,auth,payments,license}/README.md`, `app/README.md`, `scripts/run_domain_tests.{ps1,sh}` — на месте (см. корневой `README.md`).

## Роль (Ф5)
Матрица сборки и непрерывная интеграция всех частей.

## Создаваемые файлы
```
.github/workflows/ci.yml          # main: domain tests (dart), services tests (pytest), flutter analyze/test
.github/workflows/release.yml     # теги: сборка артефактов
app/README.md                     # как собрать под каждую платформу
services/converter/README.md
services/license/README.md
scripts/run_domain_tests.ps1      # цикл по packages/core/test/*_test.dart (dart)
scripts/run_domain_tests.sh
```

## Матрица платформ
| Цель | Инструмент | Примечание |
|---|---|---|
| iOS | Flutter build ios + App Store (Xcode/macOS CI) | нотаризация/TestFlight |
| Windows | Flutter build windows → MSIX или Inno Setup | установка без админа |
| macOS | Flutter build macos → DMG + notarization | macOS CI |
| Linux | Flutter build linux → AppImage/DEB | |
| Сервисы | Docker build + push (converter, license) | |

## CI-пайплайн
1. `dart test`-эквивалент: `scripts/run_domain_tests.ps1` (или .sh) — каждый `test/*_test.dart` из `packages/core`; выход 0 — все зелёные.
2. `pytest services/converter/tests services/license/tests`.
3. `flutter analyze` + `flutter test` (app) — если Flutter доступен на раннере.
4. Артефакты на тег `v*`.

## Критерии приёмки
1. CI-скрипты локально исполнимы (ps1/sh) и зелёные на текущем коде.
2. README сборки под каждую платформу с точными командами.
