// Золотой корпус геометрии: сравнение с Shapely (JSON из tool/gen_golden.py).
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import '../tool/test_utils.dart';
import '../lib/src/geom/polygon2.dart';
import '../lib/src/geom/geom_ops.dart';
import '../lib/src/geom/geom_boolean.dart';
import '../lib/src/model/vec2.dart';

List<Vec2> ringRect(double x0, double y0, double x1, double y1) =>
    [Vec2(x0, y0), Vec2(x1, y0), Vec2(x1, y1), Vec2(x0, y1)];

List<Vec2> ringCircle(double r, {int n = 192}) {
  final out = <Vec2>[];
  for (var i = 0; i < n; i++) {
    final a = 2 * math.pi * i / n;
    out.add(Vec2(r * math.cos(a), r * math.sin(a)));
  }
  return out;
}

Map<String, dynamic> metaOf(List<Polygon2> ps) {
  var area = 0.0;
  var rings = 0;
  var b = const BBox.empty();
  for (final p in ps) {
    area += p.area;
    rings += p.rings.length;
    b = b.unite(p.bounds);
  }
  return {
    'area': area,
    'minx': b.minX,
    'miny': b.minY,
    'maxx': b.maxX,
    'maxy': b.maxY,
    'rings': rings,
  };
}

void compare(String name, Map<String, dynamic> actual, Map<String, dynamic>? gold) {
  if (gold == null) {
    throw StateError('ОШИБКА ТЕСТА: $name: нет золота в JSON');
  }
  // GEOS (Shapely) аппроксимирует дуги хордами (quad_segs=8) и при эрозии
  // квадрата даёт плоские углы — расхождения до ~1 мм² против точного
  // round-join. Допуск учитывает эту аппроксимацию.
  expectNear(actual['area'] as double, gold['area'] as double, '$name area',
      eps: (gold['area'] as double) * 0.005 + 1.0);
  expectNear(actual['minx'] as double, gold['minx'] as double, '$name minx', eps: 0.1);
  expectNear(actual['miny'] as double, gold['miny'] as double, '$name miny', eps: 0.1);
  expectNear(actual['maxx'] as double, gold['maxx'] as double, '$name maxx', eps: 0.1);
  expectNear(actual['maxy'] as double, gold['maxy'] as double, '$name maxy', eps: 0.1);
  expectEq(actual['rings'], gold['rings'], '$name rings');
  ok('golden: $name');
}

void main() {
  final file = File('test/golden/geom_golden.json');
  expect(file.existsSync(), 'золотой файл существует (запусти gen_golden.py)');
  final gold = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;

  // union двух пересекающихся прямоугольников
  compare('union_rects',
      metaOf(unaryUnionPolygons([
        Polygon2([ringRect(0, 0, 10, 10)]),
        Polygon2([ringRect(5, 0, 15, 10)])
      ])),
      gold['union_rects'] as Map<String, dynamic>?);

  // buffer квадрата
  compare('buffer_sq_p1',
      metaOf(bufferPolygons([Polygon2([ringRect(0, 0, 10, 10)])], 1.0, join: 'round')),
      gold['buffer_sq_p1'] as Map<String, dynamic>?);
  compare('buffer_sq_m1',
      metaOf(bufferPolygons([Polygon2([ringRect(0, 0, 10, 10)])], -1.0, join: 'round')),
      gold['buffer_sq_m1'] as Map<String, dynamic>?);

  // полигон с отверстием (пончик)
  final donut = Polygon2([
    ringRect(0, 0, 20, 20),
    ringRect(7, 7, 13, 13),
  ]);
  compare('donut', metaOf([donut]), gold['donut'] as Map<String, dynamic>?);
  compare('donut_buf_p05',
      metaOf(bufferPolygons([donut], 0.5, join: 'round')),
      gold['donut_buf_p05'] as Map<String, dynamic>?);
  compare('donut_buf_m05',
      metaOf(bufferPolygons([donut], -0.5, join: 'round')),
      gold['donut_buf_m05'] as Map<String, dynamic>?);

  // два раздельных прямоугольника
  compare('union_disjoint',
      metaOf(unaryUnionPolygons([
        Polygon2([ringRect(0, 0, 5, 5)]),
        Polygon2([ringRect(10, 10, 15, 15)])
      ])),
      gold['union_disjoint'] as Map<String, dynamic>?);

  // круг и круг с отверстием
  final circle = Polygon2([ringCircle(10)]);
  compare('circle', metaOf([circle]), gold['circle'] as Map<String, dynamic>?);
  compare('circle_buf_p1',
      metaOf(bufferPolygons([circle], 1.0, join: 'round')),
      gold['circle_buf_p1'] as Map<String, dynamic>?);
  final donutC = Polygon2([ringCircle(10), ringCircle(4)]);
  compare('circle_donut', metaOf([donutC]), gold['circle_donut'] as Map<String, dynamic>?);
  compare('circle_donut_buf_p05',
      metaOf(bufferPolygons([donutC], 0.5, join: 'round')),
      gold['circle_donut_buf_p05'] as Map<String, dynamic>?);

  // ignore: avoid_print
  print('Все золотые тесты геометрии пройдены.');
}
