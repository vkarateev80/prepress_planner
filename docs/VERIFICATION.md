# Верификация «Препресс-Планер»

Финальная приёмка по спецификации `docs/superpowers/specs/2026-09-02-prepress-planner-design.md` §10.
Заполнено фактическими выводами команд (аг.14; дата прогона фиксируется в коммите Ф5-14).

## Критерии приёмки (§10)

| № | Критерий | Статус | Команда/факт |
|---|---|---|---|
| 1 | Запуск на iOS/Windows/macOS/Linux; импорт DXF/SVG/PDF локально, AI/CDR/EPS через сервер | ◐ | Flutter 3.47.2, ни одной pub.dev-зависимости; `app/` собирается под все платформы из одного дерева. Локально: DXF/SVG/PDF/AI(PDF-совм.) — `parse_file_test.dart` (7 OK). AI/CDR/EPS — конвертер `services/converter` (7 pytest OK; Inkscape/EPS-ветки подняты). Фактический запуск бинарей под iOS/macOS/Linux в этой среде (Windows) не выполнялся |
| 2 | Эталонная математика 1:1 (50×30 → 9×5, 112 об., 5040 шт., 34137.6 мм, отходы 26.18 %, 2032.0 мм²/шт) | ✅ | `dart tool/e2e.dart` → «Расход: 9×5, N=5040, оборотов=112, длина=34137.6, отходы=26.18%, на этикетку=2032.0»; `material_test.dart` 9 OK (rapport/row_candidates/col_candidates/count/length/rotation) |
| 3 | Shape-расход по чистой площади; оптимизация 0°/90° с efficiency | ✅ | `shape_test.dart` 7 OK (rect/roundRect/circle/ellipse/polygon + consumption); `optimizer_test.dart` 4 OK (best_variant, rotation_helps_web_narrow, narrow_web_180) |
| 4 | ТЭО: сортамент, машиночасы, скорость, переналадка, рабочее время, оснастка; C_per_1k, экономия, break-even, загрузка смены, чувствительность | ✅ | `economics_test.dart` 6 OK (reference_teo, compare_variants, break_even, catalog_json, rounding). E2E: «ТЭО: costPer1000=704.88, лучший вариант #1 (704.88 ₽/1000)»; `assortment.dart`/`machine.dart`/`teo.dart` в core |
| 5 | PDF ТЭО и XLSX формируются; DXF открываются | ✅ | `reports_test.dart` 5 OK (pdf_structure, xlsx_structure, dxf_write_roundtrip, writers_real_data) — структура проверяется PyMuPDF/zipfile |
| 6 | В `packages/core` нет модулей маски/G-кода | ✅ | grep mask|gcode|уф|уп → 0 (только «управляющие символы» в XML-комментарии) |
| 7 | Триал 15 дней + гейтинг Free/Pro | ✅ | Сервер: `services/license` pytest 10 OK (activate/validate/trial 15 d). Клиент: `license_test.dart` 5 OK + `license_ui_test.dart` 5 OK — bootstrap триала при первом запуске, чип статуса в шапке, paywall, квота Free (1 проект), гейтинг Pro-вкладок/«Перебора вариантов». iOS IAP (StoreKit) — заглушка `purchase()`, реальный IAP вне объёма MVP |
| 8 | `dart test` (домен), `pytest` (сервисы), `flutter test` зелёные; CI | ✅ | Домен: «ALL PASS (16 files)». pytest: «17 passed» (7 конвертер + 10 лицензии). Flutter: «All tests passed!» (10) + `flutter analyze` «No issues found!». CI: `.github/workflows/ci.yml`, `release.yml` |

## Сводка команд и фактические выводы

### Домен (16 тест-файлов, ALL PASS)
```
powershell -File scripts/run_domain_tests.ps1
```
Последний прогон: dxf 2 OK, economics 6 OK, geom_golden 11 OK, geom_smoke 1 OK,
healer 6 OK, inflate 7 OK, manufacturability 10 OK, material 9 OK, optimizer 4 OK,
parse_file 7 OK, pattern 1 OK, pdf 1 OK, reports 5 OK, sample 1 OK, shape 7 OK,
svg 1 OK → «ALL PASS (16 files)».

### E2E-сценарий (эталонные числа 1:1)
```
dart tool/e2e.dart   (из packages/core)   → E2E OK
1. Парсинг: 3 контуров
2. Анализ: ok=true, issues=1, вердикт: Внимание (1 предупреждений)
3. Лечение: 2 контуров, замкнуто: 2
5. Расход: 9×5, N=5040, оборотов=112, длина=34137.6, отходы=26.18%, на этикетку=2032.0
6. Расход по форме: использовано 7560000.0 мм², отходы 26.18%
7. ТЭО: costPer1000=704.88, лучший вариант #1 (704.88 ₽/1000), экономия 0.0 ₽/1000
```

### Flutter
```
cd app && flutter analyze   → No issues found!
cd app && flutter test      → All tests passed! (15: 5 widget + 5 license + 5 license_ui)
```

### Сервисы
```
python -m pytest services/converter/tests services/license/tests -q
→ 17 passed in ~5s (конвертер 7, лицензии 10)
```

## Расхождения, зафиксированные при портировании

1. Контракт 05 п.10: rotated лучше при web=180 у этикетки 60×30 (не 50×30) — проверено python-оракулом.
2. Контракт 04: quadroring.dxf — не массив этикеток (логотип с дублированным эллипсом) — оракул Python.
3. Контракт 07: runTime = length/(speed·1000)/60 ч (м/мин, не м/ч) — формула спеки §7.
4. Триал 15 дней реализован на сервере лицензий и офлайн-заглушкой клиента; iOS IAP — заглушка покупки
   (StoreKit-интеграция требует аккаунта разработчика Apple и вне объёма MVP).
