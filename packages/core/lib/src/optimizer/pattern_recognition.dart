/// Распознавание массивов Step&Repeat (порт
/// cam_material/src/optimizer/pattern_recognition.py, семантика 1:1).
///
/// Алгоритм (сверен с Python-эталоном на реальных фикстурах):
///  1. Замкнутые контуры (площадь > 5 мм²) → полигоны; если замкнутых нет —
///     полигонизация ломаных (polygonize).
///  2. Группировка полигонов по габаритам W×H (округление до целых мм);
///     главная группа (самая многочисленная) = «этикетки».
///  3. Изоляция мастер-штампа: исходные контуры, целиком лежащие в строгом
///     буфере 0.2 мм вокруг эталона; фолбэк 0.5 мм — пересечение с буфером.
///  4. Смещения = разность центроидов копий и мастера; ряды/колонки —
///     группировка центроидов с допуском; шаг = медиана шагов групп;
///     зазоры = шаг − размер этикетки (>= 0).
///  5. Закономерной сетки нет → isArray=false; для одиночного контура в
///     masterPaths кладётся сам контур (спецификация домена).
library;

import '../geom/geom_boolean.dart';
import '../geom/geom_ops.dart';
import '../geom/polygon2.dart';
import '../model/cam_path.dart';
import '../model/vec2.dart';

/// Результат анализа массива.
///
/// [isArray]=false для одиночного контура: [masterPaths] = [контур],
/// [labelW]/[labelH] по bbox, [masterArea] по площади, rows=cols=count=1,
/// шаги/зазоры = 0.
class PatternResult {
  final bool isArray;

  /// Мастер-штамп: исходные контуры внутри буфера эталона.
  final List<CamPath> masterPaths;

  /// Смещения копий от мастера (включая (0,0) самого мастера).
  final List<Vec2> offsets;

  final int rows;
  final int cols;
  final double stepX;
  final double stepY;
  final double gapX;
  final double gapY;
  final int count;
  final double labelW;
  final double labelH;

  /// Площадь внешнего контура мастера, мм².
  final double masterArea;

  const PatternResult({
    this.isArray = false,
    this.masterPaths = const [],
    this.offsets = const [],
    this.rows = 0,
    this.cols = 0,
    this.stepX = 0,
    this.stepY = 0,
    this.gapX = 0,
    this.gapY = 0,
    this.count = 0,
    this.labelW = 0,
    this.labelH = 0,
    this.masterArea = 0,
  });
}

/// Полигон + путь-источник (null — полигон получен полигонизацией).
class _PolyRec {
  final Polygon2 poly;
  final CamPath? origin;
  _PolyRec(this.poly, this.origin);
}

/// Распознаватель массивов Step&Repeat.
class PatternRecognizer {
  /// Допуск (мм) для поиска рядов и колонок (как в Python: tolerance=0.5).
  final double tolerance;

  PatternRecognizer({this.tolerance = 0.5});

  /// Анализ массива. Пустой/непригодный вход → isArray=false.
  PatternResult analyze(List<CamPath> paths) {
    // --- Шаг 0: замкнутые контуры → полигоны (area > 5), остальные — линии.
    final polys = <_PolyRec>[];
    final lines = <List<Vec2>>[];
    for (final p in paths) {
      if (p.points.length < 2) continue;
      if (p.isClosed && p.points.length >= 3) {
        try {
          final ring = cleanRing(p.points);
          if (ring.length >= 3 && ringAreaAbs(ring) > 5.0) {
            polys.add(_PolyRec(Polygon2([ring]), p));
          }
        } catch (_) {
          // невалидный контур — пропускаем (как try/except в Python)
        }
      }
      lines.add(p.points);
    }
    // Если замкнутых полигонов нет — полигонизация ломаных.
    if (polys.isEmpty && lines.isNotEmpty) {
      try {
        for (final face in polygonize(lines)) {
          if (face.area > 5.0) polys.add(_PolyRec(face, null));
        }
      } catch (_) {
        // вырожденный вход — как try/except в Python
      }
    }

    if (polys.isEmpty) return const PatternResult();

    // --- Шаг 1: группировка по габаритам W×H (округление до целых мм).
    // LinkedHashMap сохраняет порядок вставки — как dict в Python.
    final buckets = <(int, int), List<_PolyRec>>{};
    for (final pr in polys) {
      final b = pr.poly.bounds;
      buckets.putIfAbsent((b.width.round(), b.height.round()), () => []).add(pr);
    }
    // Главная группа — самая многочисленная (при равенстве — первая по
    // порядку вставки, как max() по dict в Python).
    List<_PolyRec>? mainBucket;
    for (final list in buckets.values) {
      if (mainBucket == null || list.length > mainBucket.length) {
        mainBucket = list;
      }
    }
    if (mainBucket == null || mainBucket.length < 2) {
      // Закономерной сетки нет.
      if (polys.length == 1) {
        return _singleContourResult(polys.first);
      }
      return const PatternResult();
    }

    // --- Шаг 2: мастер-штамп = «верхний-левый» из главной группы.
    mainBucket.sort(_masterComparator);
    final masterPoly = mainBucket.first.poly;
    final masterCentroid = masterPoly.centroid;
    final masterArea = masterPoly.area;

    // --- Шаг 3: изоляция мастера строгим буфером 0.2 мм, фолбэк 0.5 мм.
    final masterPaths = _isolateMaster(paths, masterPoly);

    // --- Шаг 4: смещения (разность центроидов копий и мастера).
    final offsets = <Vec2>[];
    for (final pr in mainBucket) {
      offsets.add(pr.poly.centroid - masterCentroid);
    }

    // --- Шаг 5: анализ сетки (ряды/колонки, шаг, зазоры).
    final xCentroids = mainBucket.map((pr) => pr.poly.centroid.x).toList();
    final yCentroids = mainBucket.map((pr) => pr.poly.centroid.y).toList();
    final rowGroups = _group1d(yCentroids, tolerance);
    final colGroups = _group1d(xCentroids, tolerance);
    final numRows = rowGroups.length;
    final numCols = colGroups.length;

    final stepX = numCols > 1 ? _medianStep(colGroups) : 0.0;
    final stepY = numRows > 1 ? _medianStep(rowGroups) : 0.0;

    final mb = masterPoly.bounds;
    final labelW = mb.width;
    final labelH = mb.height;

    final gapX = stepX > 0 ? _max0(stepX - labelW) : 0.0;
    final gapY = stepY > 0 ? _max0(stepY - labelH) : 0.0;

    return PatternResult(
      isArray: true,
      masterPaths: masterPaths,
      offsets: offsets,
      rows: numRows,
      cols: numCols,
      stepX: _r3(stepX),
      stepY: _r3(stepY),
      gapX: _r3(gapX),
      gapY: _r3(gapY),
      count: mainBucket.length,
      labelW: labelW,
      labelH: labelH,
      masterArea: masterArea,
    );
  }

  // ============================================================
  // Вспомогательное
  // ============================================================

  /// Результат для одиночного контура (isArray=false, спецификация домена):
  /// мастер = сам контур, размеры/площадь по нему, count=rows=cols=1.
  PatternResult _singleContourResult(_PolyRec pr) {
    final poly = pr.poly;
    final b = poly.bounds;
    final masterPath =
        pr.origin ?? CamPath(List.of(poly.outerRing), isClosed: true);
    return PatternResult(
      isArray: false,
      masterPaths: [masterPath],
      rows: 1,
      cols: 1,
      count: 1,
      labelW: b.width,
      labelH: b.height,
      masterArea: poly.area,
    );
  }

  /// Сортировка главной группы, как в Python:
  /// key = (-round(centroid.y, 1), round(centroid.x, 1)) — мастер «верхний-
  /// левый» (сначала больший y, затем меньший x).
  int _masterComparator(_PolyRec a, _PolyRec b) {
    final ca = a.poly.centroid;
    final cb = b.poly.centroid;
    final ka = -_r1(ca.y);
    final kb = -_r1(cb.y);
    if (ka != kb) return ka < kb ? -1 : 1;
    final xa = _r1(ca.x);
    final xb = _r1(cb.x);
    if (xa != xb) return xa < xb ? -1 : 1;
    return 0;
  }

  /// Изоляция мастер-штампа: исходные контуры, лежащие в буфере мастера.
  List<CamPath> _isolateMaster(List<CamPath> paths, Polygon2 masterPoly) {
    // Строгий буфер 0.2 мм: контур должен целиком лежать внутри (contains/
    // covers у shapely; здесь — все вершины внутри буферного полигона).
    final strictBuf = _bufferOf(masterPoly, 0.2);
    if (strictBuf != null) {
      final strict = <CamPath>[];
      for (final p in paths) {
        if (p.points.length < 2) continue;
        if (_lineInside(p.points, strictBuf)) strict.add(p);
      }
      if (strict.isNotEmpty) return strict;
    }
    // Резервный поиск (микро-артефакты): пересечение с буфером 0.5 мм.
    final fallbackBuf = _bufferOf(masterPoly, 0.5);
    if (fallbackBuf != null) {
      final fb = <CamPath>[];
      for (final p in paths) {
        if (p.points.length < 2) continue;
        if (_lineTouches(p.points, fallbackBuf)) fb.add(p);
      }
      if (fb.isNotEmpty) return fb;
    }
    return const [];
  }

  List<Polygon2>? _bufferOf(Polygon2 poly, double d) {
    try {
      final buf = bufferPolygons([poly], d);
      if (buf.isNotEmpty && !buf.first.isEmpty) return buf;
    } catch (_) {
      // вырожденная геометрия — как try/except в Python
    }
    return null;
  }

  /// Все вершины ломаной внутри буферной области (внешнее кольцо содержит,
  /// ни одно отверстие не содержит) — аналог contains/covers у shapely.
  bool _lineInside(List<Vec2> pts, List<Polygon2> buf) {
    for (final region in buf) {
      final outer = region.outerRing;
      final ob = region.bounds;
      var ok = true;
      for (final v in pts) {
        if (!ob.containsPoint(v, eps: 1e-6)) {
          ok = false;
          break;
        }
        if (!pointInRing(v, outer)) {
          ok = false;
          break;
        }
        for (var i = 1; i < region.rings.length; i++) {
          if (pointInRing(v, region.rings[i])) {
            ok = false;
            break;
          }
        }
        if (!ok) break;
      }
      if (ok) return true;
    }
    return false;
  }

  /// Ломаная пересекает буферную область (вершина внутри либо ребро
  /// пересекает границу) — аналог intersects у shapely (фолбэк 0.5 мм).
  bool _lineTouches(List<Vec2> pts, List<Polygon2> buf) {
    for (final region in buf) {
      final outer = region.outerRing;
      for (final v in pts) {
        if (pointInRing(v, outer)) return true;
      }
      for (var i = 0; i + 1 < pts.length; i++) {
        final a = pts[i];
        final b = pts[i + 1];
        if ((a - b).length < 1e-12) continue;
        for (var k = 0; k < outer.length; k++) {
          if (segmentIntersections(
                  a, b, outer[k], outer[(k + 1) % outer.length])
              .isNotEmpty) {
            return true;
          }
        }
      }
    }
    return false;
  }

  /// Группировка 1D-значений с допуском [tol] (как в Python): соседние
  /// значения ближе tol объединяются; центр группы — среднее.
  List<double> _group1d(List<double> values, double tol) {
    final sorted = List<double>.of(values)..sort();
    if (sorted.isEmpty) return const [];
    final groups = <double>[];
    var current = <double>[sorted.first];
    for (final v in sorted.skip(1)) {
      if (v - current.last <= tol) {
        current.add(v);
      } else {
        groups.add(_mean(current));
        current = <double>[v];
      }
    }
    groups.add(_mean(current));
    return groups;
  }

  /// Медиана шагов между отсортированными центрами групп (как в Python:
  /// steps[len(steps)//2] — «верхняя медиана»).
  double _medianStep(List<double> groups) {
    if (groups.length < 2) return 0.0;
    final steps = <double>[];
    for (var i = 1; i < groups.length; i++) {
      steps.add(groups[i] - groups[i - 1]);
    }
    steps.sort();
    return steps[steps.length ~/ 2];
  }

  double _mean(List<double> v) {
    var s = 0.0;
    for (final x in v) {
      s += x;
    }
    return s / v.length;
  }

  double _max0(double v) => v < 0 ? 0.0 : v;

  static double _r1(double v) => (v * 10).roundToDouble() / 10;

  static double _r3(double v) => (v * 1000).roundToDouble() / 1000;
}
