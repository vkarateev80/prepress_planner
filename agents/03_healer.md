# Агент 03 — Лечение и топология (packages/core/lib/src/healer/, optimizer/topology)

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
  MorphologicalHealer({double tolerance = 2.0, double minLoopArea = 1.0});
  List<CamPath> heal(List<CamPath> paths);
}

class TopologicalOptimizer {
  TopologicalOptimizer({double simplifyTolerance = 0.001});
  List<CamPath> optimize(List<CamPath> paths);
}
```

## Семантика (порт 1:1 — сверяться с morphology.py)
1. Жёсткий предфильтр пыли: отбросить объекты с площадью/длиной < minLoopArea ДО математики.
2. Снаппинг концов: пары концов ближе tolerance (по умолчанию 2.0 мм) усредняются в одну точку (сшивание разрывов). Python-реализацию портировать дословно (допуск из ManufacturingParams).
3. Слияние: `lineMerge` → разрезание пересечений (`unaryUnion` линий/нодинг) → `polygonize`.
4. Сборка: объединение полигонов (`unaryUnionPolygons`), морфологическое замыкание `buffer(0.005).buffer(−0.005)` (сварка микрощелей).
5. Извлечение внешних контуров (`layerName: 'HEALED_POLY'`) и отверстий (`'HEALED_HOLE'`); «хвосты» (линии, не вошедшие в полигоны, длиннее порога) → `'HEALED_TAIL'`.
6. `TopologicalOptimizer.optimize`: упрощение Дугласа–Пекера с preserve_topology (0.001) для удаления коллинеарных узлов.
7. Слои-маркеры: как в Python (см. morphology.py: HEALED_POLY/HEALED_HOLE/HEALED_TAIL).

## Тесты
- petlya_open_artifacts.dxf (fixtures): после heal — все контуры замкнуты (кроме HEALED_TAIL), нет пересечений; количество HEALED_POLY ≥ 1.
- Искусственный микроразрыв (две линии с зазором 0.005 мм, допуск 0.01) → после лечения одна замкнутая фигура (аналог python test_healer).
- Пыль: квадрат 0.5×0.5 при minLoopArea 1.0 удаляется.
- Топология: полилиния с 100 коллинеарными точками на отрезке → упрощается до 2 точек, геометрия не меняется (длина та же, допуск 1e-6).
- Не падает на пустом списке; на вырожденных контурах.

## Критерии приёмки
1. Все тесты зелёные. 2. Только stdlib. 3. Поведение согласовано с morphology.py (аг.14 сверяет на реальных файлах из cam_pipeline/data).
