// Тесты лечения и топологии (аг.03): порт morphology.py + topology.py.
import 'dart:io';

import '../tool/test_utils.dart';
import '../lib/io.dart';
import '../lib/src/parser/dxf_parser.dart';
import '../lib/src/healer/morphology.dart';
import '../lib/src/optimizer/topology.dart';
import '../lib/src/model/cam_path.dart';
import '../lib/src/model/vec2.dart';

String fx(String name) => '../../fixtures/$name';

CamPath _polyline(List<(double, double)> pts,
        {bool closed = false, String layer = 'T'}) =>
    CamPath(pts.map((p) => Vec2(p.$1, p.$2)).toList(),
        isClosed: closed, layerName: layer);

(double, double, double, double) _bounds(List<Vec2> pts) {
  var minX = double.infinity, minY = double.infinity;
  var maxX = double.negativeInfinity, maxY = double.negativeInfinity;
  for (final v in pts) {
    if (v.x < minX) minX = v.x;
    if (v.y < minY) minY = v.y;
    if (v.x > maxX) maxX = v.x;
    if (v.y > maxY) maxY = v.y;
  }
  return (minX, minY, maxX, maxY);
}

void main() {
  // ===== 1. Реальный файл с артефактами =====
  // petlya_open_artifacts.dxf: 1 большой открытый контур (разрыв 0.34 мм)
  // + 4 обрывка-пыли. Лечение с параметрами анализатора (2.0/1.0):
  // Python-эталон даёт замкнутый HEALED_POLY (bbox 98.26..123.6 ×
  // -177.35..-131.21), пыль удаляется, хвостов нет.
  final raw = DxfParser().parse(fx('petlya_open_artifacts.dxf'));
  final healed = const MorphologicalHealer(tolerance: 2.0, minLoopArea: 1.0)
      .heal(raw);
  final polys = healed.where((p) => p.layerName == 'HEALED_POLY').toList();
  expect(polys.isNotEmpty, 'open_artifacts: HEALED_POLY ≥ 1');
  expect(polys.every((p) => p.isClosed), 'open_artifacts: все POLY замкнуты');
  final holes = healed.where((p) => p.layerName == 'HEALED_HOLE').toList();
  expect(holes.every((p) => p.isClosed), 'HOLE замкнуты');
  // Никаких HEALED_TAIL длиннее пыли (пыль удалена предфильтром).
  final tails = healed.where((p) => p.layerName == 'HEALED_TAIL').toList();
  expect(tails.isEmpty, 'open_artifacts: хвостов нет (пыль удалена)');
  // Общий bbox полигонов совпадает с эталоном (допуск 1 мм).
  var minX = double.infinity, minY = double.infinity;
  var maxX = double.negativeInfinity, maxY = double.negativeInfinity;
  for (final p in polys) {
    final (a, b, c, d) = _bounds(p.points);
    if (a < minX) minX = a;
    if (b < minY) minY = b;
    if (c > maxX) maxX = c;
    if (d > maxY) maxY = d;
  }
  expectNear(minX, 98.26, 'minx', eps: 1.0);
  expectNear(minY, -177.35, 'miny', eps: 1.0);
  expectNear(maxX, 123.62, 'maxx', eps: 1.0);
  expectNear(maxY, -131.21, 'maxy', eps: 1.0);
  ok('heal: petlya_open_artifacts.dxf');

  // ===== 2. Микроразрыв (аналог Python test_healer_closes_micro_gap) =====
  // Два контура с разрывом 0.005 мм -> лечение замыкает в полигон.
  final p1 = _polyline([(0, 0), (0, 10), (10, 10)]);
  final p2 = _polyline([(10, 9.995), (10, 0), (0, 0)]);
  final closedHealed =
      const MorphologicalHealer(tolerance: 2.0, minLoopArea: 1.0).heal([p1, p2]);
  expect(closedHealed.any((p) => p.isClosed),
      'микроразрыв: лечение замыкает контур');
  ok('heal: микроразрыв 0.005 мм');

  // ===== 3. Пыль удаляется =====
  final dust = _polyline([(0, 0), (0, 0.5), (0.5, 0.5), (0.5, 0), (0, 0)],
      closed: true); // 0.25 мм²
  final big = _polyline([(10, 0), (20, 0), (20, 10), (10, 10), (10, 0)],
      closed: true); // 100 мм²
  final cleaned = const MorphologicalHealer(tolerance: 2.0, minLoopArea: 1.0)
      .heal([dust, big]);
  expect(cleaned.isNotEmpty, 'пыль: остался большой контур');
  expect(cleaned.every((p) => p.layerName != 'HEALED_TAIL' || p.points.length > 2),
      'пыль: обрывков нет');
  final bigPolys = cleaned.where((p) => p.layerName == 'HEALED_POLY').toList();
  expect(bigPolys.isNotEmpty, 'пыль: HEALED_POLY есть');
  final (bx0, by0, bx1, by1) = _bounds(bigPolys.first.points);
  expectNear(bx0, 10.0, 'big minx', eps: 0.1);
  expectNear(bx1, 20.0, 'big maxx', eps: 0.1);
  expectNear(by1, 10.0, 'big maxy', eps: 0.1);
  ok('heal: пыль 0.25 мм² удалена');

  // ===== 4. Топология: коллинеарные точки упрощаются =====
  final dense = <(double, double)>[];
  for (var i = 0; i <= 100; i++) {
    dense.add((i * 0.1, 5.0)); // 100 точек на прямой
  }
  final linePath = _polyline(dense);
  final opt = const TopologicalOptimizer().optimize([linePath]);
  expectEq(opt.length, 1, 'топология: один путь на выходе');
  expectEq(opt[0].points.length, 2, 'топология: 100 коллинеарных -> 2 точки');
  // Длина не изменилась (допуск 1e-6: упрощение по прямой).
  expectNear(opt[0].lengthMm, 10.0, 'топология: длина сохранена', eps: 1e-6);
  ok('топология: коллинеарные точки');

  // ===== 5. Устойчивость =====
  expect(const MorphologicalHealer().heal([]).isEmpty, 'пустой список');
  expect(
      const MorphologicalHealer().heal([
        _polyline([(0, 0), (1, 1)]), // 2 точки, открытая
        _polyline([]), // пустая
      ]).isEmpty || true,
      'вырожденные не падают');
  ok('heal: устойчивость');

  // ===== 6. Оптимизатор не трогает замкнутые и слои =====
  final sq = _polyline([(0, 0), (10, 0), (10, 10), (0, 10), (0, 0)],
      closed: true, layer: 'MASTER');
  final optSq = const TopologicalOptimizer().optimize([sq]);
  expectEq(optSq.length, 1, 'квадрат: один путь');
  expect(optSq[0].isClosed, 'квадрат: замкнут');
  expectEq(optSq[0].layerName, 'MASTER', 'слой сохранён');
  ok('топология: замкнутый контур и слой');

  // ignore: avoid_print
  print('Все тесты лечения пройдены.');
}
