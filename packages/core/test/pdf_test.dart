// Тесты PDF-парсера (оракул: cam_material/src/parser/pdf_parser.py + PyMuPDF).
import '../tool/test_utils.dart';
import '../lib/src/parser/pdf_parser.dart';
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
  final parser = PdfParser();

  // petlya.pdf и quadroring.pdf — один артворк (A4, 1 путь из 4 кубиков,
  // замкнут). Оракул Python: 1 путь, closed=1, pts=801,
  // bounds ≈ (98.12, 119.72, 123.61, 165.85).
  for (final name in ['petlya.pdf', 'quadroring.pdf']) {
    final paths = parser.parse(fx(name));
    expectEq(paths.length, 1, '$name: 1 контур');
    expect(paths[0].isClosed, '$name: замкнут');
    expect(paths[0].points.length > 400 && paths[0].points.length < 1200,
        '$name: число точек ~801');
    final (x0, y0, x1, y1) = boundsOf(paths);
    expectNear(x0, 98.12, '$name minx', eps: 2.0);
    expectNear(y0, 119.72, '$name miny', eps: 2.0);
    expectNear(x1, 123.61, '$name maxx', eps: 2.0);
    expectNear(y1, 165.85, '$name maxy', eps: 2.0);
  }

  // petlya_open_artifacts.pdf (Adobe Illustrator-экспорт): поток со zlib-обёрткой
  // и мультиблочным хвостом — локальная распаковка не поддерживается; по
  // контракту 02 ожидается понятная ошибка (серверная конвертация).
  var threw = false;
  var msg = '';
  try {
    parser.parse(fx('petlya_open_artifacts.pdf'));
  } catch (e) {
    threw = true;
    msg = e.toString();
  }
  expect(threw, 'open_artifacts.pdf: ожидаемый отказ локального парсинга');
  expect(msg.contains('контура') || msg.contains('PDF'), 'русское сообщение об ошибке');

  // Слой — PDF_VECTOR (проверяем на успешно распарсенных petlya).
  final plCheck = parser.parse(fx('petlya.pdf'));
  expect(plCheck.every((p) => p.layerName == 'PDF_VECTOR'), 'слой PDF_VECTOR');

  ok('pdf_parser');
  // ignore: avoid_print
  print('Все тесты PDF-парсера пройдены.');
}
