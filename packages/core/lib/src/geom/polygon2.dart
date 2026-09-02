/// Геометрический тип «полигон»: внешнее кольцо + отверстия.
///
/// Кольца — списки [Vec2] (мм). Кольцо считается замкнутым неявно
/// (ребро от последней точки к первой); допускается явное повторение
/// первой точки в конце — функции устойчивы к обоим представлениям.
library;

import '../model/vec2.dart';

/// Прямоугольная оболочка (bounds).
class BBox {
  final double minX, minY, maxX, maxY;

  const BBox(this.minX, this.minY, this.maxX, this.maxY);

  /// Пустая оболочка: min > max, без NaN.
  const BBox.empty()
      : minX = double.infinity,
        minY = double.infinity,
        maxX = double.negativeInfinity,
        maxY = double.negativeInfinity;

  bool get isEmpty => minX > maxX || minY > maxY;

  double get width => isEmpty ? 0.0 : maxX - minX;

  double get height => isEmpty ? 0.0 : maxY - minY;

  Vec2 get center =>
      isEmpty ? const Vec2(0, 0) : Vec2((minX + maxX) / 2, (minY + maxY) / 2);

  /// Расширенная оболочка (d >= 0 наружу).
  BBox expand(double d) {
    if (isEmpty) return this;
    final dd = d < 0 ? 0.0 : d;
    return BBox(minX - dd, minY - dd, maxX + dd, maxY + dd);
  }

  /// Объединение с другой оболочкой.
  BBox unite(BBox o) {
    if (isEmpty) return o;
    if (o.isEmpty) return this;
    return BBox(
        minX < o.minX ? minX : o.minX,
        minY < o.minY ? minY : o.minY,
        maxX > o.maxX ? maxX : o.maxX,
        maxY > o.maxY ? maxY : o.maxY);
  }

  bool containsPoint(Vec2 p, {double eps = 1e-9}) =>
      !isEmpty &&
      p.x >= minX - eps &&
      p.x <= maxX + eps &&
      p.y >= minY - eps &&
      p.y <= maxY + eps;

  @override
  String toString() =>
      isEmpty
          ? 'BBox(empty)'
          : 'BBox(${minX.toStringAsFixed(4)}, ${minY.toStringAsFixed(4)}, '
                '${maxX.toStringAsFixed(4)}, ${maxY.toStringAsFixed(4)})';
}

/// Полигон: [rings][0] — внешний контур, остальные — отверстия.
///
/// Ориентация колец произвольна: все вычисления берут модуль знаковой
/// площади, поэтому результат не зависит от направления обхода.
class Polygon2 {
  final List<List<Vec2>> rings;

  const Polygon2(this.rings);

  bool get isEmpty =>
      rings.isEmpty ||
      rings[0].length < 3 ||
      _signedArea(rings[0]).abs() <= 1e-12;

  /// Площадь, мм²: |внешнее| − Σ|отверстия| (не может быть < 0).
  double get area {
    if (rings.isEmpty) return 0.0;
    var outer = _signedArea(rings[0]).abs();
    if (outer <= 1e-12) return 0.0;
    for (var i = 1; i < rings.length; i++) {
      outer -= _signedArea(rings[i]).abs();
      if (outer < 0) outer = 0.0; // мусорный вход — устойчиво
    }
    return outer;
  }

  /// Геометрический центр тяжести (с учётом отверстий).
  Vec2 get centroid {
    if (rings.isEmpty) return const Vec2(0, 0);
    var ax = 0.0, ay = 0.0, sw = 0.0;
    for (var i = 0; i < rings.length; i++) {
      final ring = rings[i];
      if (ring.length < 3) continue;
      final sa = _signedArea(ring);
      if (sa.abs() <= 1e-14) continue;
      final w = i == 0 ? sa.abs() : -sa.abs(); // внешнее +, дыры −
      final c = _signedCentroid(ring);
      ax += w * c.x;
      ay += w * c.y;
      sw += w;
    }
    if (sw.abs() <= 1e-12) return _fallbackCentroid();
    return Vec2(ax / sw, ay / sw);
  }

  /// Оболочка всех колец.
  BBox get bounds {
    var b = const BBox.empty();
    for (final r in rings) {
      b = b.unite(_ringBounds(r));
    }
    return b;
  }

  /// Внешнее кольцо без явного дублирования первой точки.
  List<Vec2> get outerRing {
    if (rings.isEmpty) return const [];
    final r = rings[0];
    if (r.length >= 2 && _eq(r.first, r.last)) {
      return List.of(r.sublist(0, r.length - 1));
    }
    return List.of(r);
  }

  Vec2 _fallbackCentroid() {
    // Вырожденная геометрия: центр среднего всех вершин (без NaN).
    final r = outerRing;
    if (r.isEmpty) return const Vec2(0, 0);
    var x = 0.0, y = 0.0;
    for (final p in r) {
      x += p.x;
      y += p.y;
    }
    return Vec2(x / r.length, y / r.length);
  }

  @override
  String toString() => 'Polygon2(${rings.length} колец)';
}

/// Знаковая площадь кольца по формуле шнурков (CCW — положительная).
/// Кольцо трактуется как неявно замкнутое; явный дубль первой точки в
/// конце не искажает результат (даёт нулевое замыкающее ребро).
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

/// Центроид кольца по шнуркам (корректен при любой ориентации).
Vec2 _signedCentroid(List<Vec2> ring) {
  final n = ring.length;
  if (n < 3) return const Vec2(0, 0);
  var a = 0.0, cx = 0.0, cy = 0.0;
  for (var i = 0; i < n; i++) {
    final p = ring[i];
    final q = ring[(i + 1) % n];
    final cross = p.x * q.y - q.x * p.y;
    a += cross;
    cx += (p.x + q.x) * cross;
    cy += (p.y + q.y) * cross;
  }
  if (a.abs() <= 1e-14) return const Vec2(0, 0);
  return Vec2(cx / (3 * a), cy / (3 * a));
}

/// Оболочка одного кольца (пустой результат при < 2 точек).
BBox _ringBounds(List<Vec2> ring) {
  if (ring.isEmpty) return const BBox.empty();
  var minX = double.infinity, minY = double.infinity;
  var maxX = double.negativeInfinity, maxY = double.negativeInfinity;
  final n = _pointCount(ring);
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

/// Число вершин кольца без учёта возможного дубля замыкания.
int _pointCount(List<Vec2> ring) {
  if (ring.isEmpty) return 0;
  if (ring.length >= 2 && _eq(ring.first, ring.last)) return ring.length - 1;
  return ring.length;
}

bool _eq(Vec2 a, Vec2 b) => (a.x - b.x).abs() < 1e-9 && (a.y - b.y).abs() < 1e-9;
