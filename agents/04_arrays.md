# Агент 04 — Массивы: распознавание и генерация (packages/core/lib/src/optimizer/)

## Роль
Порт распознавания массивов Step & Repeat и генератора сеток (размножение мастер-штампа) в Dart. Потребляет аг.01 (geom), аг.02 (model).

## Источники (читать)
- `cam_material/src/optimizer/pattern_recognition.py` (PatternRecognizer — порт 1:1)
- `cam_pipeline/src/pipeline/cam_pipeline.py` → `multiply_paths(self, paths, offsets)` (строки ~39)
- `cam_pipeline/src/core/controller.py` → `open_array_generator` (строки ~416) — логика ручной сетки и авто-подбора рядов под раппорт шестерни

## Создаваемые файлы
```
packages/core/lib/src/optimizer/pattern_recognition.dart
packages/core/lib/src/optimizer/array_generator.dart
packages/core/test/pattern_test.dart
```

## Интерфейс (ТОЧНО)

```dart
class PatternResult {
  final bool isArray;
  final List<CamPath> masterPaths;   // мастер-штамп (внутри буфера эталона)
  final List<Vec2> offsets;          // смещения копий от мастера
  final int rows, cols;
  final double stepX, stepY, gapX, gapY;
  final int count;
  final double labelW, labelH;       // bbox мастера
  final double masterArea;           // площадь полигона мастера (для shape-расхода)
  const PatternResult.isolated(this.masterPaths, this.labelW, this.labelH, this.masterArea, {this.isArray=false, ...});
}

class PatternRecognizer {
  PatternRecognizer({double tolerance = 0.5});
  PatternResult analyze(List<CamPath> paths);
}

// Генератор (порт multiply_paths + open_array_generator)
// Смещения сетки: for c in 0..cols-1, r in 0..rows-1: (c·stepX, −r·stepY)
// (ось Y вверх → ряды уходят ВНИЗ; копия при (0,0) — сам мастер, итого cols×rows путей).
List<CamPath> multiplyPaths(List<CamPath> master, List<Vec2> offsets, {String layerName = 'ARRAY'});
// клонирует КАЖДЫЙ путь master для КАЖДОГО offset: точка + offset, округление до 4 знаков, isClosed сохраняется
int autoRowsForRapport(double rapport, double labelH, double minGap);   // rows_max = int(rapport // (labelH + minGap))
List<CamPath> generateArrayGrid(List<CamPath> master,
    {required int cols, required int rows, required double stepX, required double stepY,
     String layerName = 'ARRAY'});
// эквивалент UI: stepX = labelW+gapX, stepY = labelH+gapY (или rapport/rows для авто-Y)
```

## Семантика (сверяться с Python)
1. Полигонизация замкнутых контуров площадью > 5 мм² (или polygonize по линиям, если замкнутых нет).
2. Группировка по габаритам W×H (округление до мм); главная группа = этикетки.
3. Изоляция мастера: строгий буфер 0.2 мм вокруг эталона (contains/covers по всем путям), фолбэк 0.5 мм.
4. Смещения = разность центроидов; группировка строк/колонок с tolerance; медианный шаг X/Y; зазоры = шаг − размер; итог rows×cols.
5. Если массив не найден: `isArray=false` (+ labelW/H/masterArea по bbox всей геометрии, если один замкнутый контур).
6. `masterArea` — площадь внешнего контура мастера (для расходов по чистой площади).

## Тесты
- `fixtures/quadroring.dxf`/`.svg`/`.pdf`: распознаётся массив: `isArray=true`, rows≥2, cols≥2, count≥4; bbox этикетки ~одинаковый во всех форматах (допуск 0.5 мм); gapX/gapY ≥ 0.
- Синтетика: мастер-квадрат 10×10, сетка 3×2, шаг 20/15 → recognize возвращает rows=2, cols=3, stepX=20, stepY=15, count=6.
- `generateArrayGrid(master, cols:2, rows:3, stepX:20, stepY:15)` → count=6; смещения копий = (0,0),(20,0),(0,−15),(20,−15),(0,−30),(20,−30); bounds копий согласуются со смещениями (допуск 1e-6).
- `autoRowsForRapport(304.8, 30, 3) == 9`.
- `multiplyPaths(master, offsets)` — геометрия копий идентична мастеру (bounds сдвинуты точно на offset).
- Одиночный контур (petlya.dxf) → isArray=false.

## Критерии приёмки
1. Все тесты зелёные. 2. Только stdlib. 3. Имена/сигнатуры точные (потребляет аг.05).
