/// Геометрические операции: метрики, предикаты, упрощение.
///
/// Контракт: agents/01_geometry.md. Чистый Dart, без зависимостей.
/// Кольца трактуются как неявно замкнутые (ребро от последней к первой точке);
/// явный дубль первой точки в конце допустим и устойчиво обрабатывается.
library;

import 'dart:math' as math;
import 'polygon2.dart';
import '../model/cam_path.dart';
import '../model/vec2.dart';

// ============================================================
// Метрики
// ============================================================

double _signedArea(List<Vec2> ring) {
  if (ring.length < 3) return 0.0;
  var s = 0.0;
  final n = ring.length;
  for (var i = 0; i < n; i++) {
    final a = ring[i];
    final b = ring[(i + 1) % n];
    s += a.x * b.y - b.x * a.y;
  }
  return s / 2;
}

/// Знаковая площадь кольца (положительна при обходе против часовой, CCW).
double ringArea(List<Vec2> ring) => _signedArea(ring);

/// Площадь по модулю.
double ringAreaAbs(List<Vec2> ring) => _signedArea(ring).abs();

/// Центроид кольца (по шнуркам; при вырождении — среднее вершин).
Vec2 ringCentroid(List<Vec2> ring) {
  final n = ring.length;
  if (n < 3) {
    return ring.isEmpty ? const Vec2(0, 0) : _mean(ring);
  }
  var a = 0.0, cx = 0.0, cy = 0.0;
  for (var i = 0; i < n; i++) {
    final p = ring[i];
    final q = ring[(i + 1) % n];
    final cross = p.x * q.y - q.x * p.y;
    a += cross;
    cx += (p.x + q.x) * cross;
    cy += (p.y + q.y) * cross;
  }
  if (a.abs() <= 1e-14) return _mean(ring);
  return Vec2(cx / (3 * a), cy / (3 * a));
}

Vec2 _mean(List<Vec2> ring) {
  var x = 0.0, y = 0.0;
  for (final p in ring) {
    x += p.x;
    y += p.y;
  }
  return ring.isEmpty ? const Vec2(0, 0) : Vec2(x / ring.length, y / ring.length);
}

/// Оболочка кольца.
BBox ringBounds(List<Vec2> ring) {
  if (ring.isEmpty) return const BBox.empty();
  var minX = double.infinity, minY = double.infinity;
  var maxX = double.negativeInfinity, maxY = double.negativeInfinity;
  final n = ring.length;
  for (var i = 0; i < n; i++) {
    final p = ring[i];
    if (p.x < minX) minX = p.x;
    if (p.y < minY) minY = p.y;
    if (p.x > maxX) maxX = p.x;
    if (p.y > maxY) maxY = p.y;
  }
  if (minX > maxX || minY > maxY) return const BBox.empty();
  return BBox(minX, minY, maxX, maxY);
}

// ============================================================
// Предикаты
// ============================================================

const double _eps = 1e-9;

/// Точка внутри кольца (ray-cast; граница считается «внутри»).
bool pointInRing(Vec2 p, List<Vec2> ring) {
  if (ring.length < 3) return false;
  var inside = false;
  var j = ring.length - 1;
  for (var i = 0; i < ring.length; i++) {
    final a = ring[i];
    final b = ring[j];
    // На границе — считаем внутри.
    if (pointSegmentDistance(p, a, b) < 1e-9) return true;
    final intersects = (a.y > p.y) != (b.y > p.y);
    if (intersects) {
      final xCross = (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x;
      if (p.x < xCross) inside = !inside;
    }
    j = i;
  }
  return inside;
}

/// Полностью ли [inner] лежит внутри [outer] (все вершины внутри И нет
/// пересечений рёбер, кроме касания). Используется для изоляции мастер-штампа.
bool ringCoversRing(List<Vec2> outer, List<Vec2> inner) {
  if (outer.length < 3 || inner.isEmpty) return false;
  final ob = ringBounds(outer);
  final ib = ringBounds(inner);
  if (ib.isEmpty) return false;
  // Быстрая отсечка по оболочке.
  if (ib.minX < ob.minX - 1e-7 || ib.maxX > ob.maxX + 1e-7 ||
      ib.minY < ob.minY - 1e-7 || ib.maxY > ob.maxY + 1e-7) {
    return false;
  }
  // Каждая вершина inner — внутри outer.
  for (final v in inner) {
    if (!pointInRing(v, outer)) return false;
  }
  // Ни одно ребро inner не пересекает рёбра outer «по-настоящему».
  final on = outer.length, inn = inner.length;
  for (var i = 0; i < on; i++) {
    final a1 = outer[i], a2 = outer[(i + 1) % on];
    for (var k = 0; k < inn; k++) {
      final b1 = inner[k], b2 = inner[(k + 1) % inn];
      final pts = segmentIntersections(a1, a2, b1, b2);
      for (final x in pts) {
        // Точка пересечения не должна быть общей вершиной (касание допустимо).
        final isVertex = _nearAny(x, [a1, a2, b1, b2]);
        if (!isVertex) return false;
      }
    }
  }
  return true;
}

/// Точки пересечения отрезков [a1]-[a2] и [b1]-[b2]: 0, 1 или 2 точки
/// (2 — при коллинеарном перекрытии: концы общей части).
List<Vec2> segmentIntersections(Vec2 a1, Vec2 a2, Vec2 b1, Vec2 b2) {
  final r = a2 - a1;
  final s = b2 - b1;
  final denom = r.cross(s);
  final qp = b1 - a1;

  if (denom.abs() < 1e-12) {
    // Параллельны или коллинеарны.
    if (qp.cross(r).abs() >= 1e-9) return const []; // параллельны, не пересекаются
    // Коллинеарны: ищем перекрытие проекций на ось r.
    final r2 = r.lengthSquared;
    if (r2 < 1e-18) return const [];
    double proj(Vec2 p) => (p - a1).dot(r) / r2;
    final t0 = proj(b1), t1 = proj(b2);
    var lo = t0 < t1 ? t0 : t1;
    var hi = t0 < t1 ? t1 : t0;
    final lo2 = 0.0, hi2 = 1.0;
    lo = lo < lo2 ? lo2 : lo;
    hi = hi > hi2 ? hi2 : hi;
    if (hi < lo - 1e-9) return const [];
    if ((hi - lo).abs() < 1e-9) {
      // Единственная общая точка — конец одного отрезка на другом.
      if (hi.abs() > 1e12) return const [];
      final p = a1 + r * ((lo + hi) / 2);
      return _dedupe([p]);
    }
    if ((hi - lo).abs() < 1e-7) return _dedupe([a1 + r * lo, a1 + r * hi]);
    // Полное/частичное перекрытие: 2 точки.
    return _dedupe([a1 + r * lo, a1 + r * hi]);
  }

  final t = qp.cross(s) / denom;
  final u = qp.cross(r) / denom;
  if (t < -1e-9 || t > 1 + 1e-9 || u < -1e-9 || u > 1 + 1e-9) return const [];
  return _dedupe([a1 + r * t]);
}

List<Vec2> _dedupe(List<Vec2> pts) {
  final out = <Vec2>[];
  for (final p in pts) {
    if (!out.any((q) => (q - p).length < 1e-7)) out.add(p);
  }
  return out;
}

bool _nearAny(Vec2 p, List<Vec2> cands) =>
    cands.any((c) => (c - p).length < 1e-7);

/// Кратчайшее расстояние от точки [p] до отрезка [a]-[b].
double pointSegmentDistance(Vec2 p, Vec2 a, Vec2 b) {
  final ab = b - a;
  final l2 = ab.lengthSquared;
  if (l2 < 1e-18) return (p - a).length;
  var t = (p - a).dot(ab) / l2;
  if (t < 0) t = 0;
  if (t > 1) t = 1;
  return (p - (a + ab * t)).length;
}

/// Расстояние от точки до бесконечной прямой через [a]-[b].
double _pointLineDistance(Vec2 p, Vec2 a, Vec2 b) {
  final ab = b - a;
  final l = ab.length;
  if (l < 1e-18) return (p - a).length;
  return ((p - a).cross(ab)).abs() / l;
}

// ============================================================
// Упрощение (Дуглас–Пекер)
// ============================================================

/// Упрощение кольца с допуском [tolerance] (preserve closure).
List<Vec2> simplifyRing(List<Vec2> ring, double tolerance) {
  if (tolerance <= 0) return List.of(ring);
  var pts = _stripDup(ring);
  if (pts.length < 3) return pts;
  final closed = (ring.length >= 3) &&
      ((ring.first - ring.last).length < 1e-9 ||
          (pts.isNotEmpty && ring.isNotEmpty && (ring.first - ring.last).length < 1e-6));
  if (!closed && pts.length < 2) return pts;
  if (closed) {
    // Разрезаем кольцо в вершине, наиболее удалённой от первой, и
    // упрощаем как открытую цепочку с возвратом в начало.
    // Проще: добавить первую точку в конец и обработать как открытую цепь.
    final chain = List<Vec2>.of(pts)..add(pts.first);
    final simp = _dp(chain, tolerance);
    // Убрать дубль первой точки в конце, если он остался.
    var out = simp;
    if (out.length >= 2 && (out.first - out.last).length < 1e-9) {
      out = List.of(out.sublist(0, out.length - 1));
    }
    if (out.length >= 3) return out;
    return pts; // слишком выродилось — вернуть исходное кольцо
  }

  final simp = _dp(pts, tolerance);
  return simp.length >= 2 ? simp : pts;
}

List<Vec2> _stripDup(List<Vec2> pts) {
  final out = <Vec2>[];
  for (final p in pts) {
    if (out.isEmpty || (out.last - p).length > 1e-9) out.add(p);
  }
  return out;
}

List<Vec2> _dp(List<Vec2> pts, double tol) {
  if (pts.length < 3) return List.of(pts);
  final keep = List<bool>.filled(pts.length, false);
  keep[0] = true;
  keep[pts.length - 1] = true;
  final stack = <List<int>>[
    [0, pts.length - 1]
  ];
  while (stack.isNotEmpty) {
    final seg = stack.removeLast();
    final i0 = seg[0], i1 = seg[1];
    if (i1 <= i0 + 1) continue;
    var maxD = -1.0, idx = -1;
    for (var i = i0 + 1; i < i1; i++) {
      final d = _pointLineDistance(pts[i], pts[i0], pts[i1]);
      if (d > maxD) {
        maxD = d;
        idx = i;
      }
    }
    if (idx >= 0 && maxD > tol) {
      keep[idx] = true;
      stack.add([i0, idx]);
      stack.add([idx, i1]);
    }
  }
  final out = <Vec2>[];
  for (var i = 0; i < pts.length; i++) {
    if (keep[i]) out.add(pts[i]);
  }
  return out;
}

// ============================================================
// Преобразования
// ============================================================

/// CamPath → полигон (внешнее кольцо; отверстия — отдельными вызовами).
Polygon2 camPathToPolygon(CamPath p) {
  final ring = _stripDup(p.points);
  return Polygon2([ring]);
}

/// Нормализация ориентации: внешнее кольцо — CCW, отверстия — CW.
List<List<Vec2>> normalizeRings(Polygon2 poly) {
  final out = <List<Vec2>>[];
  if (poly.rings.isEmpty) return out;
  final outer = _orient(poly.rings[0], ccw: true);
  if (outer != null) out.add(outer);
  for (var i = 1; i < poly.rings.length; i++) {
    final hole = _orient(poly.rings[i], ccw: false);
    if (hole != null) out.add(hole);
  }
  return out;
}

List<Vec2>? _orient(List<Vec2> ring, {required bool ccw}) {
  var pts = _stripDup(ring);
  if (pts.length < 3) return null;
  if (pts.length >= 2 && (pts.first - pts.last).length < 1e-9) {
    pts = List.of(pts.sublist(0, pts.length - 1));
  }
  if (pts.length < 3) return null;
  final s = ringArea(pts);
  final wantPositive = ccw;
  if ((s > 0) == wantPositive) return pts;
  return pts.reversed.toList();
}

/// Проверить, что кольцо замкнуто неявно либо явно; вернуть «чистое» кольцо
/// без явного дубля первой точки (для построения полигонов).
List<Vec2> cleanRing(List<Vec2> ring) {
  var pts = _stripDup(ring);
  if (pts.length >= 2 && (pts.first - pts.last).length < 1e-9) {
    pts = List.of(pts.sublist(0, pts.length - 1));
  }
  return pts;
}

/// Угол (в радианах) между векторами (a→b) и (b→c) в точке b: 0..π.
double angleAt(Vec2 a, Vec2 b, Vec2 c) {
  final v1 = b - a;
  final v2 = c - b;
  final l1 = v1.length;
  final l2 = v2.length;
  if (l1 < 1e-12 || l2 < 1e-12) return math.pi;
  var dot = v1.dot(v2) / (l1 * l2);
  dot = dot.clamp(-1.0, 1.0);
  return math.acos(dot);
}
