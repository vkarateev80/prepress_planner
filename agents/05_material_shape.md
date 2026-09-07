# Агент 05 — Расход материала, форма этикетки, оптимизация раскроя (packages/core/lib/src/calculator/)

> **Актуализация 2026-09-07 (HEAD 448dcba):** статус — актуально. Математика реализована 1:1 с эталонами (`material_test.dart`, `shape_test.dart`, `optimizer_test.dart` зелёные). Рейтинг по магнитным валам Z и кнопка «Применить» для вариантов — UI-надстройка приложения над `computeMaterialAuto` (коммиты `8a57827`, `448dcba`), ядро не менялось.

## Роль
Порт 1:1 математики расхода из `cam_material/src/calculator/material.py` и `optimizer.py` + **новая** shape-модель (чистая площадь формы) и свод расхода. Потребляет аг.04 (PatternResult.masterArea).

## Источники (читать)
- `cam_material/src/calculator/material.py` — ВЕСЬ файл (порт 1:1)
- `cam_material/src/calculator/optimizer.py` — перебор вариантов
- `cam_material/tests/test_material_calc.py`, `test_optimizer.py` — эталонные тесты (перенести)

## Создаваемые файлы
```
packages/core/lib/src/calculator/material.dart
packages/core/lib/src/calculator/shape.dart
packages/core/lib/src/calculator/consumption.dart
packages/core/lib/src/calculator/layout_optimizer.dart
packages/core/test/material_test.dart
packages/core/test/shape_test.dart
packages/core/test/optimizer_test.dart
```

## Интерфейс (ТОЧНО)

```dart
class GearInfo { final double rapport, dPitch, dCyl; }
GearInfo gearInfo(int z, double cp, double undercut, {double manual = 0});

class MaterialResult {
  // поля как в python compute() (см. ниже)
  final String? error;                 // null — успех
  final double labelW, labelH;         // с учётом rotated
  final bool rotated;
  final double gapX, gapYRequested, gapYActual, stepX, stepY;
  final int rows, cols;
  final double usedWidth, webMin;
  final int perRev, revs, count, countRequested, excessLabels;
  final double rapport, dPitch, dCyl, length, webWidth;
  final double areaMm2, areaM2, usedAreaMm2, wastePct, perLabelArea;
  final String mode;
}

MaterialResult computeMaterial(LayoutParams p, {int? rows, int? cols, bool rotated = false});
MaterialResult computeMaterialAuto(LayoutParams p);
double computeRapportValue(int z, double cp, {double manual = 0});
List<int> rowCandidates(double rapport, double labelH, double minGap);
List<int> colCandidates(double limitWidth, double labelW, double gapX);
int? pickRows(double rapport, double labelH, double gapY, double minGap);
```

**Поля python `compute()` → Dart** (1:1, имена из python):
`label_w,label_h,rotated,gap_x,gap_y_requested,rows,cols,step_x,step_y,gap_y_actual,used_width,web_min,per_rev,rapport,d_pitch,d_cyl,mode,count,count_requested,revs,length,web_width,area_mm2,area_m2,used_area_mm2,waste_pct,per_label_area,excess_labels`; ошибки — ключ `error` (в Dart поле `error`).

## Shape (новое)
```dart
class LabelShape {
  final String kind;          // 'rect'|'roundRect'|'circle'|'ellipse'|'polygon'
  final double w, h;          // bbox W×H (драйвер сетки)
  final double area;          // чистая площадь, мм² (S)
  final double efficiency;    // S / (W·H)
}
LabelShape shapeFromPreset(String kind, double w, double h, {double radius = 0}); // circle: w==h==d
LabelShape shapeFromPolygon(List<Vec2> ring);       // из мастер-штампа (аг.04) — area по полигону
```

## Consumption (новое)
```dart
class Consumption {
  final double areaMm2, areaM2, usedAreaMm2, wasteMm2, wastePct, perLabelMm2, webMin;
}
Consumption computeConsumption(MaterialResult calc, LabelShape shape);
// usedArea = count · S(shape); waste = area − usedArea; perLabel = area/count
```

## Optimizer (порт)
```dart
List<MaterialResult> enumerateVariants(LayoutParams p, {int limit = 50}); // лучший первый: (perLabelArea, wastePct)
```

## Эталонные тесты (ПЕРЕНОС, значения ТОЧНЫЕ — из test_material_calc.py)
1. `computeRapportValue(96, 3.175) == 304.8`; manual=300 → 300.0; `(100, 2.5) == 250.0`.
2. `gearInfo(96,3.175,0.48)`: rapport=304.8, dPitch=304.8/π, dCyl=304.8/π−0.96 (допуск 1e-3).
3. `rowCandidates(304.8, 30, 3) == [1..9]`; `(304.8, 400, 3) == []`.
4. `pickRows(304.8,30,3,3)==9`; `pickRows(304.8,30,8,3)==8`; `pickRows(304.8,400,3,3)==null`.
5. `colCandidates(300,50,3) == [1..5]`; `(300,400,3)==[]`.
6. **Главный эталон** (LayoutParams 50×30, gap 3/3, Z=96, CP=3.175, cyl=web=300, minGap=3, count=5000):
   `rows==9, cols==5, gapYActual≈304.8/9−30, perRev==45, revs==112, length≈112·304.8, count==5040, excess==40, usedWidth==262.0, areaMm2≈112·304.8·300, wastePct≈26.18, perLabelArea≈2032.0` (допуски как в python).
7. Length-режим: L=10000 → revs==32, count==32·45, perLabelArea==2032.0.
8. Ошибки: этикетка 400 мм в раппорт → error; 400 мм в ширину → error; длина < раппорта → error.
9. Поворот: rotated=True с rows=5,cols=9 → labelW/labelH меняются местами, perRev==45.
10. `enumerateVariants`: лучший первый; варианты rotated:
    - web=250, этикетка 60×30 → лучший **не-rotated** (9×4=36); этикетка 30×60 → лучший **rotated** (поворот даёт 36 вместо 28) — как в python test_optimizer.py.
    - web=180, этикетка 60×30 → лучший **rotated** (4×5=20 > 9×2=18) — проверено живым оракулом optimizer.py.
    - ВНИМАНИЕ (исправление контракта): для web=180 и этикетки 50×30 rotated НЕ лучше (не-rotated 9×3=27 > rotated 5×5=25). Ранее контракт ошибочно утверждал обратное.

## Shape-тесты (новые)
- rect 50×30: S=1500, efficiency=1.0.
- roundRect 50×30 R=5: S = 1500 − (4−π)·25 ≈ 1478.54 (допуск 0.01); efficiency<1.
- circle d=30: S=π·225≈706.86.
- ellipse 50×30: S=π·25·15≈1178.10.
- polygon-квадрат: S == W·H.
- **Consumption**: rect → usedArea == count·W·H (совпадает со старым расчётом); круг d=30 в той же сетке → wastePct выше (материал между кругами — отход), perLabelArea == area/count.

## Критерии приёмки
1. Все перенесённые эталоны зелёные (значения выше). 2. Только stdlib. 3. Имена точные (потребляет аг.07 ТЭО).
