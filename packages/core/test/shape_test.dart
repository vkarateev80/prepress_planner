// Тесты shape-модели (чистая площадь формы) и свода расхода.
import 'dart:math' as math;

import '../tool/test_utils.dart';
import '../lib/src/model/params.dart';
import '../lib/src/model/vec2.dart';
import '../lib/src/calculator/material.dart';
import '../lib/src/calculator/shape.dart';
import '../lib/src/calculator/consumption.dart';

void testRect() {
  final s = shapeFromPreset('rect', 50, 30);
  expectEq(s.kind, 'rect', 'kind');
  expectNear(s.area, 1500.0, 'area rect', eps: 1e-9);
  expectNear(s.efficiency, 1.0, 'efficiency rect', eps: 1e-9);
  ok('shape_rect');
}

void testRoundRect() {
  final s = shapeFromPreset('roundRect', 50, 30, radius: 5);
  // area = w*h - (4-pi)*r*r = 1500 - 0.8584073...*25
  final expected = 1500.0 - (4.0 - math.pi) * 25.0;
  expectNear(s.area, expected, 'area roundRect', eps: 0.01);
  expectNear(s.area, 1478.54, 'area roundRect ~1478.54', eps: 0.01);
  expect(s.efficiency < 1.0, 'efficiency roundRect < 1');
  ok('shape_roundRect');
}

void testCircle() {
  final s = shapeFromPreset('circle', 30, 30);
  // area = pi * (d/2)^2 = pi * 225
  expectNear(s.area, math.pi * 225.0, 'area circle', eps: 0.01);
  expectNear(s.area, 706.86, 'area circle ~706.86', eps: 0.01);
  expectNear(s.efficiency, math.pi / 4.0, 'efficiency circle', eps: 1e-6);
  ok('shape_circle');
}

void testEllipse() {
  final s = shapeFromPreset('ellipse', 50, 30);
  // area = pi * (w/2) * (h/2) = pi * 25 * 15
  expectNear(s.area, math.pi * 25.0 * 15.0, 'area ellipse', eps: 0.01);
  expectNear(s.area, 1178.10, 'area ellipse ~1178.10', eps: 0.01);
  ok('shape_ellipse');
}

void testPolygon() {
  // квадрат 50x30: площадь по шнуркам == W*H
  final ring = <Vec2>[
    const Vec2(0, 0),
    const Vec2(50, 0),
    const Vec2(50, 30),
    const Vec2(0, 30),
  ];
  final s = shapeFromPolygon(ring);
  expectEq(s.kind, 'polygon', 'kind polygon');
  expectNear(s.w, 50.0, 'bbox w', eps: 1e-9);
  expectNear(s.h, 30.0, 'bbox h', eps: 1e-9);
  expectNear(s.area, 1500.0, 'area polygon', eps: 1e-9);
  expectNear(s.area, s.w * s.h, 'area == W*H', eps: 1e-9);
  expectNear(s.efficiency, 1.0, 'efficiency polygon', eps: 1e-9);
  ok('shape_polygon');
}

MaterialResult baseCalc() => computeMaterialAuto(LayoutParams(
      labelW: 50,
      labelH: 30,
      gapX: 3,
      gapY: 3,
      zTeeth: 96,
      cp: 3.175,
      cylWidth: 300,
      webWidth: 300,
      minGap: 3,
      mode: 'count',
      count: 5000,
    ));

void testConsumptionRect() {
  final calc = baseCalc();
  expect(calc.error == null, 'baseCalc не должен падать');
  final s = shapeFromPreset('rect', 50, 30);
  final c = computeConsumption(calc, s);
  // usedArea == count * W*H и согласуется со старым расчётом (used_area в калькуляторе)
  expectNear(c.usedAreaMm2, calc.count * 50.0 * 30.0, 'usedArea == count*W*H',
      eps: 1e-6);
  expectNear(c.usedAreaMm2, calc.usedAreaMm2, 'usedArea == calc.usedAreaMm2',
      eps: 1e-6);
  expectNear(c.perLabelMm2, calc.areaMm2 / calc.count,
      'perLabelMm2 == calc.areaMm2/count', eps: 1e-6);
  // consumption.wastePct — сырое значение по формуле waste/area*100,
  // calc.wastePct — то же значение, округлённое до 2 знаков в порту Python.
  expectNear(c.wastePct, calc.wastePct, 'wastePct == calc.wastePct',
      eps: 0.01);
  expectNear(c.webMin, calc.webMin, 'webMin', eps: 1e-9);
  expectNear(c.areaMm2, calc.areaMm2, 'areaMm2', eps: 1e-9);
  expectNear(c.areaM2, calc.areaM2, 'areaM2', eps: 1e-9);
  expect(c.wasteMm2 >= 0, 'wasteMm2 >= 0');
  ok('consumption_rect');
}

void testConsumptionCircle() {
  final calc = baseCalc();
  final rect = computeConsumption(calc, shapeFromPreset('rect', 50, 30));
  final s = shapeFromPreset('circle', 30, 30);
  final c = computeConsumption(calc, s);
  // круг в той же сетке -> отходов больше
  expect(c.wastePct > rect.wastePct, 'круг: wastePct выше');
  expectNear(c.perLabelMm2, calc.areaMm2 / calc.count,
      'perLabelMm2 == calc.areaMm2/count', eps: 1e-6);
  expect(c.usedAreaMm2 < rect.usedAreaMm2, 'круг: чистая площадь меньше');
  ok('consumption_circle');
}

void main() {
  testRect();
  testRoundRect();
  testCircle();
  testEllipse();
  testPolygon();
  testConsumptionRect();
  testConsumptionCircle();
  // ignore: avoid_print
  print('Все тесты shape и свода расхода пройдены.');
}
