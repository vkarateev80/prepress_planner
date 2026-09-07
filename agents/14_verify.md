# Агент 14 — Интеграция и верификация (E2E)

> **Актуализация 2026-09-07 (HEAD 448dcba):** статус — актуально.
> - Актуальная приёмка — `docs/VERIFICATION.md`: часть A (MVP по §10, историческая) + часть B (дополнительная приёмка 2026-09-07: аккаунты/подписка, Web-версия, развёртывание, сборки, документы); контекст — `docs/HANDOFF.md` (снимок 2026-09-07).
> - E2E-скрипт `packages/core/tool/e2e.dart` существует и подтверждён (эталонные числа 1:1, см. VERIFICATION A2); греп-контроль по маске/G-коду в `packages/core` — чист (A1.6).
> - Корневой `README.md` обновлён 2026-09-07 (обзор, сборки, ограничения).

## Роль (Ф5)
Сквозная проверка всего сценария на реальных файлах, миграция/дублирование Python-эталонов, финальная приёмка по спецe §10, документация.

## Задачи
1. **E2E-скрипт** `packages/core/tool/e2e.dart`: quadroring.dxf → parse → analyzeManufacturability → healGeometry → PatternRecognizer → generateArrayGrid (если нужно) → computeMaterialAuto (50×30/зазоры 3/Z96/CP3.175/N5000) → consumption → computeTeo → writeDxf/writeTeoXlsx (временные файлы) — печатает сводку; выход 0.
2. **Сверка с Python-эталонами** (допуск): для quadroring.dxf/python pipeline (cam_material venv python + shapely) — bounds/площади/количество контуров после лечения совпадают с Dart (допуск 0.05 мм / ±5%).
3. **Греп-контроль**: в `packages/core` нет следов mask/gcode/УФ/УП (исключая словарь, если он там появится): `grep -riE 'uv_mask|gcode|g_code|уф.маск|управляющ' packages/core` → 0 совпадений.
4. **Приёмка по спецe** (§10): все 8 пунктов — отчёт в `docs/VERIFICATION.md` с фактическими выводами команд.
5. Документация: корневой `README.md` (обзор, структура, запуск тестов), обновление дизайн-документа при расхождениях.

## Тесты/проверки
- E2E зелёный на quadroring (dxf/svg/pdf) и petlya_open_artifacts.
- PDF-отчёт открывается (python fitz), XLSX открывается (python zipfile+xml).
- Все критерии §10 спеки подтверждены командами в VERIFICATION.md.

## Критерии приёмки
1. `tool/e2e.dart` выход 0. 2. VERIFICATION.md заполнен фактическими результатами. 3. README корня написан.
