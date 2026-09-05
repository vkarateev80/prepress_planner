// Тесты DXF-парсера (эталон: ezdxf make_path + flattening, cam_pipeline).
import '../tool/test_utils.dart';
import '../lib/io.dart';
import '../lib/src/parser/dxf_parser.dart';
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
  final parser = DxfParser();

  // quadroring.dxf: 1 POLYLINE + 2 SPLINE — все замкнуты (эталон Python).
  final qr = parser.parse(fx('quadroring.dxf'));
  expectEq(qr.length, 3, 'quadroring: 3 контура');
  expect(qr.every((p) => p.isClosed), 'quadroring: все замкнуты (эталон closed=3)');
  final (qx0, qy0, qx1, qy1) = boundsOf(qr);
  expectNear(qx0, 74.6, 'quadroring minx', eps: 1.0);
  expectNear(qy0, -156.2, 'quadroring miny', eps: 1.0);
  expectNear(qx1, 117.0, 'quadroring maxx', eps: 1.0);
  expectNear(qy1, -78.9, 'quadroring maxy', eps: 1.0);

  // petlya.dxf: 1 замкнутый SPLINE.
  final pl = parser.parse(fx('petlya.dxf'));
  expectEq(pl.length, 1, 'petlya: 1 контур');
  expect(pl[0].isClosed, 'petlya: замкнут (эталон closed=1)');
  final (px0, py0, px1, py1) = boundsOf(pl);
  expectNear(px0, 98.1, 'petlya minx', eps: 1.0);
  expectNear(py0, -177.3, 'petlya miny', eps: 1.0);
  expectNear(px1, 123.6, 'petlya maxx', eps: 1.0);
  expectNear(py1, -131.2, 'petlya maxy', eps: 1.0);

  // petlya_open_artifacts.dxf: 1 SPLINE (замкнут) + 4 POLYLINE (открыты).
  final po = parser.parse(fx('petlya_open_artifacts.dxf'));
  expectEq(po.length, 5, 'open_artifacts: 5 контуров');
  final closedCount = po.where((p) => p.isClosed).length;
  expectEq(closedCount, 1, 'open_artifacts: 1 замкнут (эталон)');

  // Общие свойства: координаты конечны, путь короче 1 м (масштаб мм).
  for (final p in qr) {
    for (final v in p.points) {
      expect(!v.x.isNaN && !v.y.isNaN && v.x.abs() < 1e5 && v.y.abs() < 1e5,
          'координаты конечны');
    }
  }
  // Единицы: DXF в мм (INSUNITS=4) — размах quadroring ~42 мм по X.
  final spanX = qx1 - qx0;
  expectNear(spanX, 117.0 - 74.6, 'масштаб мм (INSUNITS=4)', eps: 1.0);

  // Несуществующий файл — понятная ошибка.
  var threw = false;
  try {
    parser.parse(fx('no_such_file.dxf'));
  } catch (e) {
    threw = e.toString().contains('не найден');
  }
  expect(threw, 'ошибка «файл не найден»');

  ok('dxf_parser');
  // ignore: avoid_print
  print('Все тесты DXF-парсера пройдены.');
}
