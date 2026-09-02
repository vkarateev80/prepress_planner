# Агент 01 — Геометрическое ядро (packages/core/lib/src/geom/)

## Роль
Порт операций Shapely, необходимых домену, в чистый Dart (только stdlib). Потребляется агентами 03 (лечение), 04 (массивы), 05 (расход/форма), 06 (технологичность).

## Источники (эталон поведения)
- Python+Shapely доступен: `cam_pipeline\venv\Scripts\python.exe` (shapely 2.x). Сравнение — через **золотой корпус** (см. ниже), не в рантайме.

## Создаваемые файлы
```
packages/core/pubspec.yaml            # name: prepress_core, sdk '>=3.0.0 <4.0.0', dev: test (недоступен pub → без dev-зависимостей, тесты своим раннером см.ниже)
packages/core/lib/prepress_core.dart  # export-барель
packages/core/lib/src/model/vec2.dart
packages/core/lib/src/model/cam_path.dart
packages/core/lib/src/geom/polygon2.dart
packages/core/lib/src/geom/geom_ops.dart
packages/core/lib/src/geom/geom_ops.dart  → методы ниже
packages/core/test/…                   # юнит-тесты
```

## Интерфейс (ТОЧНО)

```dart
class Polygon2 {
  final List<List<Vec2>> rings;   // rings[0] — внешний контур, остальные — отверстия
  const Polygon2(this.rings);
  double get area;                // внешний − Σ отверстий (по формуле шнурков)
  Vec2 get centroid;
  BBox get bounds;                // class BBox { double minX,minY,maxX,maxY; }
}

// Только stdlib, без зависимостей.
// distance > 0 — расширение наружу; < 0 — внутрь. join: 'miter'|'round'|'bevel'; mitreLimit как у shapely (по умолч. 5.0).
List<Polygon2> bufferPolygons(List<Polygon2> input, double distance,
    {String join = 'miter', double mitreLimit = 5.0});

List<Polygon2> unaryUnionPolygons(List<Polygon2> input);   // булево объединение (Martinez–Rueda или эквивалент)
List<List<Vec2>> lineMerge(List<List<Vec2>> lines);        // сшивка коллинеарных/наложенных цепочек
List<Polygon2> polygonize(List<List<Vec2>> lines);         // грани планарного графа
List<Vec2> simplifyRing(List<Vec2> ring, double tolerance);   // Дуглас–Пекер, preserve_topology
double ringArea(List<Vec2> ring);                          // знаковая площадь
Vec2 ringCentroid(List<Vec2> ring);
BBox ringBounds(List<Vec2> ring);
bool pointInRing(Vec2 p, List<Vec2> ring);                 // ray-cast
bool ringCoversRing(List<Vec2> outer, List<Vec2> inner);   // все точки inner внутри outer И нет пересечений рёбер
List<Vec2> segmentIntersections(Vec2 a, Vec2 b, Vec2 c, Vec2 d); // 0..2 точки
double pointSegmentDistance(Vec2 p, Vec2 a, Vec2 b);
Polygon2 camPathToPolygon(CamPath p);                      // из model
```

## Требования к реализации
- Устойчивость: нулевые/вырожденные кольца → пустые результаты, не NaN/исключения. Все функции идемпотентны на «мусоре».
- Точность: результаты согласуются с Shapely в допуске 0.01 мм на золотом корпусе.
- `simplifyRing` должен удалять коллинеарные точки и не размыкать кольцо.
- Числа округлять до 4 знаков только на выходных границах отчёта; внутри — double.

## Золотой корпус (обязателен)
1. Создать `packages/core/tool/gen_golden.py` (запуск: `cam_pipeline\venv\Scripts\python.exe packages/core/tool/gen_golden.py`), который:
   - читает `fixtures/quadroring.dxf` (ezdxf) и строит полигоны Shapely;
   - генерирует синтетические случаи: два пересекающихся прямоугольника (union), «петля» (linemerge/polygonize из fixtures/petlya.dxf), буферы квадрата/круга/полигона с дырой на ±0.5, ±2.0;
   - пишет JSON в `packages/core/test/golden/*.json` (WKT-геометрии результатов + площади/центроиды).
2. Dart-тесты читают золото и сравнивают: bounds/area в допуске 0.01 мм; количество колец совпадает.
3. Property-тесты: случайные кольца (seed) → buffer(1).buffer(−1) не даёт NaN и площадь ≥ 0; union двух одинаковых = одно кольцо.

## Критерии приёмки
1. `dart test` (из packages/core; запуск: `.tools\dart-sdk\bin\dart.exe test` через собственный раннер, см. агент 00/05) — все тесты зелёные. Если `dart test` недоступен без pub: создать минимальный раннер `tool/run_tests.dart`, исполняющий тест-файлы и печатающий OK/FAIL, код выхода 0/1.
2. Золотой корпус пройден (допуск 0.01 мм).
3. Нет импортов вне stdlib.
