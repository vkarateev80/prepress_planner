// Смоук-тест геометрического ядра (агент 01, быстрая проверка).
import '../tool/test_utils.dart';
import '../lib/src/geom/polygon2.dart';
import '../lib/src/geom/geom_ops.dart';
import '../lib/src/geom/geom_boolean.dart';
import '../lib/src/model/vec2.dart';

List<Vec2> rect(double x0, double y0, double x1, double y1) => [
      Vec2(x0, y0),
      Vec2(x1, y0),
      Vec2(x1, y1),
      Vec2(x0, y1),
    ];

void main() {
  // --- метрики ---
  final sq = rect(0, 0, 10, 10);
  expectNear(ringArea(sq).abs(), 100.0, 'площадь квадрата', eps: 1e-9);
  final c = ringCentroid(sq);
  expectNear(c.x, 5.0, 'центроид x', eps: 1e-9);
  expectNear(c.y, 5.0, 'центроид y', eps: 1e-9);
  final b = ringBounds(sq);
  expectNear(b.width, 10.0, 'bounds width', eps: 1e-9);

  // --- предикаты ---
  expect(pointInRing(const Vec2(5, 5), sq), 'точка внутри');
  expect(!pointInRing(const Vec2(15, 5), sq), 'точка снаружи');
  expect(pointInRing(const Vec2(10, 5), sq), 'точка на границе — внутри');
  final inner = rect(1, 1, 9, 9);
  expect(ringCoversRing(sq, inner), 'внешнее покрывает внутреннее');
  final out1 = rect(20, 20, 30, 30);
  expect(!ringCoversRing(sq, out1), 'не покрывает снаружи');

  // --- пересечения ---
  final inter = segmentIntersections(
      const Vec2(0, 0), const Vec2(10, 10), const Vec2(0, 10), const Vec2(10, 0));
  expectEq(inter.length, 1, 'пересечение отрезков');
  expectNear(inter[0].x, 5.0, 'x пересечения', eps: 1e-7);
  final par = segmentIntersections(
      const Vec2(0, 0), const Vec2(10, 0), const Vec2(0, 5), const Vec2(10, 5));
  expectEq(par.length, 0, 'параллельные не пересекаются');
  final col = segmentIntersections(
      const Vec2(0, 0), const Vec2(10, 0), const Vec2(5, 0), const Vec2(15, 0));
  expectEq(col.length, 2, 'коллинеарное перекрытие — 2 точки');

  // --- simplify: коллинеарные точки убираются ---
  final zig = <Vec2>[
    const Vec2(0, 0),
    const Vec2(2, 0),
    const Vec2(4, 0),
    const Vec2(4, 2),
    const Vec2(4, 4),
    const Vec2(4, 6),
  ];
  final simp = simplifyRing(zig, 0.001);
  expectEq(simp.length, 3, 'simplify убирает коллинеарные точки');

  // --- polygonize: квадрат из 4 отрезков ---
  final sides = <List<Vec2>>[
    [const Vec2(0, 0), const Vec2(10, 0)],
    [const Vec2(10, 0), const Vec2(10, 10)],
    [const Vec2(10, 10), const Vec2(0, 10)],
    [const Vec2(0, 10), const Vec2(0, 0)],
  ];
  final faces = polygonize(sides);
  expectEq(faces.length, 1, 'polygonize: одна грань');
  if (faces.isNotEmpty) {
    expectNear(faces[0].area, 100.0, 'polygonize: площадь грани', eps: 0.01);
  }

  // --- polygonize: замкнутое кольцо с дублем первой точки ---
  final closedRing = <Vec2>[...rect(0, 0, 10, 10), rect(0, 0, 10, 10).first];
  final faces2 = polygonize([closedRing]);
  expectEq(faces2.length, 1, 'polygonize: кольцо с дублем = 1 грань');
  if (faces2.isNotEmpty) {
    expectNear(faces2[0].area, 100.0, 'polygonize: площадь кольца', eps: 0.01);
  }

  // --- lineMerge ---
  final merged = lineMerge([
    [const Vec2(0, 0), const Vec2(1, 0)],
    [const Vec2(1, 0), const Vec2(2, 0)],
  ]);
  expectEq(merged.length, 1, 'lineMerge: одна цепочка');
  if (merged.isNotEmpty) {
    expectEq(merged[0].length, 3, 'lineMerge: 3 точки');
  }

  // --- unaryUnion: два пересекающихся прямоугольника ---
  final u = unaryUnionPolygons([Polygon2([rect(0, 0, 10, 10)]), Polygon2([rect(5, 0, 15, 10)])]);
  expectEq(u.length, 1, 'union: один полигон');
  if (u.isNotEmpty) {
    expectNear(u[0].area, 150.0, 'union: площадь 150', eps: 0.05);
  }

  // --- buffer квадрата +1 (round) → площадь ≈ 140 + π ---
  final buf = bufferPolygons([Polygon2([sq])], 1.0, join: 'round');
  expectEq(buf.length, 1, 'buffer: один полигон');
  if (buf.isNotEmpty) {
    expectNear(buf[0].area, 140.0 + 3.14159265, 'buffer +1 площадь', eps: 1.0);
  }
  // round-trip: buffer(+1).buffer(−1) ≈ исходник
  final back = bufferPolygons(buf, -1.0, join: 'round');
  expectEq(back.length, 1, 'buffer round-trip: один полигон');
  if (back.isNotEmpty) {
    expectNear(back[0].area, 100.0, 'buffer round-trip площадь', eps: 2.0);
  }

  // --- устойчивость ---
  expectEq(polygonize(const []).length, 0, 'polygonize пусто');
  expectEq(unaryUnionPolygons(const []).length, 0, 'union пусто');
  expectEq(bufferPolygons(const [], 1.0).length, 0, 'buffer пусто');
  // вырожденное кольцо
  final bad = unaryUnionPolygons([Polygon2([const [Vec2(0, 0), Vec2(1, 1)]])]);
  expect(bad.every((p) => !p.area.isNaN), 'нет NaN на мусоре');

  ok('geom_smoke');
  // ignore: avoid_print
  print('Все смоук-тесты геометрии пройдены.');
}
