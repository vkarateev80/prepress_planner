import 'dart:math' as math;

/// Точка 2D (координаты в мм).
class Vec2 {
  final double x;
  final double y;
  const Vec2(this.x, this.y);

  Vec2 operator +(Vec2 o) => Vec2(x + o.x, y + o.y);
  Vec2 operator -(Vec2 o) => Vec2(x - o.x, y - o.y);
  Vec2 operator *(double s) => Vec2(x * s, y * s);

  double get length => math.sqrt(x * x + y * y);
  double get lengthSquared => x * x + y * y;

  Vec2 get normalized {
    final l = length;
    return l < 1e-12 ? const Vec2(0, 0) : Vec2(x / l, y / l);
  }

  double dot(Vec2 o) => x * o.x + y * o.y;
  double cross(Vec2 o) => x * o.y - y * o.x;

  Vec2 round4() => Vec2(_r4(x), _r4(y));

  static double _r4(double v) => (v * 10000).roundToDouble() / 10000;

  @override
  String toString() => '(${x.toStringAsFixed(4)}, ${y.toStringAsFixed(4)})';

  @override
  bool operator ==(Object other) =>
      other is Vec2 && (other.x - x).abs() < 1e-9 && (other.y - y).abs() < 1e-9;

  @override
  int get hashCode => Object.hash((x * 1e6).round(), (y * 1e6).round());
}
