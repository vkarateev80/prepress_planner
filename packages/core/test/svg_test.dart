// Тесты SVG-парсера (оракул: cam_material/src/parser/svg_parser.py + svgelements).
import '../tool/test_utils.dart';
import '../lib/io.dart';
import '../lib/src/parser/svg_parser.dart';
import '../lib/src/model/cam_path.dart';
import '../lib/src/model/vec2.dart';

String fx(String name) => '../../fixtures/$name';

(double, double, double, double) boundsOf(List<CamPath> paths) {
  var minX = double.infinity, minY = double.infinity;
  var maxX = double.negativeInfinity, maxY = double.negativeInfinity;
  for (final p in paths) {
    for (final v in p.points) {
      if (v.x < minX) minX = v.x;
      if (v.y < minY) minY = v.y;
      if (v.x > maxX) maxX = v.x;
      if (v.y > maxY) maxY = v.y;
    }
  }
  return (minX, minY, maxX, maxY);
}

void main() {
  final parser = SvgParser();

  // quadroring.svg: rect + 2 эллипса (CorelDRAW, 210mm/21000) — тот же
  // артворк, что quadroring.dxf. Оракул Python: 3 пути, все замкнуты,
  // bounds ≈ (74.6, −156.2, 117.0, −78.8).
  final qr = parser.parse(fx('quadroring.svg'));
  expectEq(qr.length, 3, 'quadroring.svg: 3 контура');
  expectEq(qr.where((p) => p.isClosed).length, 3, 'quadroring.svg: 3 замкнуты');
  final (qx0, qy0, qx1, qy1) = boundsOf(qr);
  expectNear(qx0, 74.61, 'qr.svg minx', eps: 1.5);
  expectNear(qy0, -156.19, 'qr.svg miny', eps: 1.5);
  expectNear(qx1, 117.01, 'qr.svg maxx', eps: 1.5);
  expectNear(qy1, -78.75, 'qr.svg maxy', eps: 1.5);

  // petlya.svg: 1 путь с кубиками, замкнут (оракул: 1 путь, closed, 
  // bounds ≈ (0.07, −34.68, 19.19, −0.08)).
  final pl = parser.parse(fx('petlya.svg'));
  expectEq(pl.length, 1, 'petlya.svg: 1 контур');
  expect(pl[0].isClosed, 'petlya.svg: замкнут');
  final (px0, py0, px1, py1) = boundsOf(pl);
  expectNear(px0, 0.07, 'petlya.svg minx', eps: 1.0);
  expectNear(py0, -34.68, 'petlya.svg miny', eps: 1.0);
  expectNear(px1, 19.19, 'petlya.svg maxx', eps: 1.0);
  expectNear(py1, -0.08, 'petlya.svg maxy', eps: 1.0);

  // petlya_open_artifacts.svg: петля + 3 мелких артефакта (оракул: 4 пути,
  // 0 замкнутых, bounds ≈ (0.07, −34.73, 19.1, −0.11)).
  final po = parser.parse(fx('petlya_open_artifacts.svg'));
  expectEq(po.length, 4, 'open_artifacts.svg: 4 контура');
  expectEq(po.where((p) => p.isClosed).length, 0, 'open_artifacts.svg: 0 замкнутых');
  final (ox0, oy0, ox1, oy1) = boundsOf(po);
  expectNear(ox0, 0.07, 'po.svg minx', eps: 1.0);
  expectNear(oy0, -34.73, 'po.svg miny', eps: 1.0);
  expectNear(ox1, 19.1, 'po.svg maxx', eps: 1.0);
  expectNear(oy1, -0.11, 'po.svg maxy', eps: 1.0);

  // Слой — SVG_VECTOR (как в Python).
  expect(qr.every((p) => p.layerName == 'SVG_VECTOR'), 'слой SVG_VECTOR');

  // Несуществующий файл — понятная ошибка.
  var threw = false;
  try {
    parser.parse(fx('no_such_file.svg'));
  } catch (e) {
    threw = e.toString().contains('не найден');
  }
  expect(threw, 'ошибка «файл не найден»');

  ok('svg_parser');
  // ignore: avoid_print
  print('Все тесты SVG-парсера пройдены.');
}
