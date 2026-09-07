# Агент 03 — Лечение и топология (packages/core/lib/src/healer/, optimizer/topology)

> **Актуализация 2026-09-07 (HEAD 448dcba):** статус — актуально. Контракт соответствует коду (`packages/core/lib/src/healer/morphology.dart`, `packages/core/lib/src/optimizer/topology.dart`); лечение/анализ на контурах-гигантах ускорены bbox-сетками (коммит `2f1513c`), семантика не менялась.

## Роль
Порт морфологического лечения и топологической очистки из Python в Dart. Потребляет аг.01 (geom), аг.02 (parser/model). Служит входом для аг.04–06 и финального «Вылеченный мастер».

## Источники (читать и портировать СЕМАНТИКУ 1:1)
- `cam_material/src/healer/morphology.py` (MorphologicalHealer)
- `cam_material/src/optimizer/topology.py` (TopologicalOptimizer)
- `cam_material/src/manufacturability/analyzer.py` (heal_geometry — порядок вызовов)

## Создаваемые файлы
```
packages/core/lib/src/healer/morphology.dart
packages/core/lib/src/optimizer/topology.dart
packages/core/test/healer_test.dart
```

## Интерфейс (ТОЧНО)

```dart
class MorphologicalHealer {
  MorphologicalHealer({double tolerance = 0.01, double minLoopArea = 0.0});
  // ЗАМЕТКА: дефолты класса в Python — 0.01/0.0; analyzer.healGeometry
  // вызывает с параметрами ManufacturingParams (tolerance=2.0, minLoopArea=1.0).
  List<CamPath> heal(List<CamPath> paths);
}

class TopologicalOptimizer {
  TopologicalOptimizer({double simplifyTolerance = 0.001});
  List<CamPath> optimize(List<CamPath> paths);
}
```

## Семантика (порт 1:1 — ПОСЛЕДОВАТЕЛЬНОСТЬ ИЗ morphology.py)
Порядок операций ТОЧНО как в `MorphologicalHealer.heal()`:
1. **Жёсткий предфильтр пыли** (до математики): для каждого пути с ≥2 точек: если `minLoopArea > 0`: замкнутый (is_closed или совпали концы) → построить полигон, площадь < minLoopArea → выбросить; если полигон не строится → выбросить; незамкнутый → длина < minLoopArea → выбросить.
2. **Снаппинг концов** (`_snap_endpoints`): собрать концы всех линий; для каждой пары концов с расстоянием 0 < d ≤ tolerance — заменить оба на среднюю точку. Затем пересобрать линии: начало/конец из снапнутых точек; если расстояние между концами < 1e-4 — замкнуть (конец = начало).
3. **Слияние**: `lineMerge` снапнутых линий.
4. **Нодинг + полигонизация**: `unaryUnion`(линий) → `polygonize`; пост-фильтр: оставить полигоны с площадью ≥ minLoopArea.
5. **Сборка**: `unaryUnionPolygons`(полигонов) → **сварка** `buffer(+0.005, join:'round')` затем `buffer(−0.005, join:'round')` (в Python `join_style=1` = ROUND).
6. **Извлечение**: внешний контур каждого полигона → `CamPath(isClosed:true, layerName:'HEALED_POLY')`; каждое отверстие (interior) → отдельный `CamPath(isClosed:true, layerName:'HEALED_HOLE')`. Координаты округлить до 4 знаков. MultiPolygon — рекурсивно.
7. **Хвосты**: если полигоны есть: `remaining = noded_lines − union(всех exterior)` (разность линий); иначе remaining = noded_lines. `lineMerge`(remaining) → каждая линия длиной ≥ minLoopArea → `CamPath(isClosed:false, layerName:'HEALED_TAIL')`.
8. `TopologicalOptimizer.optimize`: для каждого пути ≥2 точек: замкнутый с ≥3 → simplify как кольцо (preserve_topology, допуск 0.001), иначе как ломаная; округлить до 4 знаков; сохранить layerName/isClosed.

## Тесты
- petlya_open_artifacts.dxf (fixtures): после heal — все контуры замкнуты (кроме HEALED_TAIL), нет пересечений; количество HEALED_POLY ≥ 1.
- Искусственный микроразрыв (две линии с зазором 0.005 мм, допуск 0.01) → после лечения одна замкнутая фигура (аналог python test_healer).
- Пыль: квадрат 0.5×0.5 при minLoopArea 1.0 удаляется.
- Топология: полилиния с 100 коллинеарными точками на отрезке → упрощается до 2 точек, геометрия не меняется (длина та же, допуск 1e-6).
- Не падает на пустом списке; на вырожденных контурах.

## Критерии приёмки
1. Все тесты зелёные. 2. Только stdlib. 3. Поведение согласовано с morphology.py (аг.14 сверяет на реальных файлах из cam_pipeline/data).
