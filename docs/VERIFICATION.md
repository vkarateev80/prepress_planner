# Верификация «Препресс-Планер»

Финальная приёмка по спецификации `docs/superpowers/specs/2026-09-02-prepress-planner-design.md` §10.
Заполняется фактическими выводами команд (аг.14).

## Критерии приёмки (§10)

| № | Критерий | Статус | Команда/факт |
|---|---|---|---|
| 1 | Запуск и сквозной сценарий на iOS/Windows/macOS/Linux; импорт DXF/SVG/PDF локально, AI/CDR/EPS через сервер | ☐ | — |
| 2 | Эталонная математика 1:1 (50×30 → 9×5, 112 об., 5040 шт., 34137.6 мм, отходы 26.18 %, 2032.0 мм²/шт) | ☐ | `dart test/material_test.dart` |
| 3 | Shape-расход по чистой площади; оптимизация 0°/90° с efficiency | ☐ | `dart test/shape_test.dart`, `optimizer_test.dart` |
| 4 | ТЭО: сортамент, машиночасы, скорость, переналадка, рабочее время, оснастка; C_per_1k, экономия, break-even, загрузка смены, чувствительность | ☐ | `dart test/economics_test.dart` |
| 5 | PDF ТЭО и XLSX формируются; DXF открываются | ☐ | `dart test/reports_test.dart` + PyMuPDF/zipfile |
| 6 | В `packages/core` нет модулей маски/G-кода | ✅ | grep mask|gcode|уф|уп → 0 (только «управляющие символы» в XML-комментарии) |
| 7 | Триал 15 дней + гейтинг Free/Pro на всех платформах; iOS — IAP | ☐ | pytest services/license; widget-тесты license |
| 8 | `dart test` (домен) и `pytest` (сервисы) зелёные; CI | ☐ | scripts/run_domain_tests.*; .github/workflows |

## Сводка команд

### Домен (16 тест-файлов, ALL PASS)
```
powershell -File scripts/run_domain_tests.ps1
```
### E2E-сценарий
```
dart packages/core/tool/e2e.dart   (из packages/core) → E2E OK
```
### Flutter
```
cd app && flutter analyze && flutter test
```
### Сервисы
```
python -m pytest services/converter/tests -q
python -m pytest services/license/tests -q
```

## Расхождения, зафиксированные при портировании

1. Контракт 05 п.10: rotated лучше при web=180 у этикетки 60×30 (не 50×30) — проверено python-оракулом.
2. Контракт 04: quadroring.dxf — не массив этикеток (логотип с дублированным эллипсом) — оракул Python.
3. Контракт 07: runTime = length/(speed·1000)/60 ч (м/мин, не м/ч) — формула спеки §7.
