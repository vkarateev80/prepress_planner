// Тесты распознавания массивов Step&Repeat и генератора сетки (аг.04).
//
// Оракул: cam_material/src/optimizer/pattern_recognition.py (запущен на той
// же геометрии, что отдают Dart-парсеры — см. tool/zz_oracle.py):
//   quadroring.dxf/.svg  -> is_array=True,  count=2, rows=1, cols=1,
//                           step=0/0, gap=0/0, label 42.397 x 43.715
//   quadroring.pdf       -> is_array=False (это артворк петли: см. pdf_test)
//   petlya.{dxf,svg,pdf} -> is_array=False
//
// ВАЖНО про quadroring.dxf/.svg: файл — это НЕ массив этикеток, а один логотип
// (прямоугольник 21.5x33 + два ОДИНАКОВЫХ эллипса 42.4x43.7; дубль эллипса —
// артефакт экспорта CorelDRAW). Python-эталон тем не менее считает группу из
// 2 контуров одинакового размера «массивом»: is_array=True, count=2,
// rows=cols=1 (вырожденный 1x1, смещения ~0). Порт 1:1 обязан это повторять.
import '../tool/test_utils.dart';
import '../lib/io.dart';
import '../lib/src/parser/dxf_parser.dart';
import '../lib/src/parser/svg_parser.dart';
import '../lib/src/parser/pdf_parser.dart';
import '../lib/src/optimizer/pattern_recognition.dart';
import '../lib/src/optimizer/array_generator.dart';
import '../lib/src/model/cam_path.dart';
import '../lib/src/model/vec2.dart';

String fx(String name) => '../../fixtures/$name';

CamPath square(double x0, double y0) => CamPath(
    [Vec2(x0, y0), Vec2(x0 + 10, y0), Vec2(x0 + 10, y0 + 10), Vec2(x0, y0 + 10)],
    isClosed: true);

bool sameVecSet(List<Vec2> a, List<Vec2> b, {double eps = 1e-6}) {
  if (a.length != b.length) return false;
  final matched = List<bool>.filled(b.length, false);
  for (final va in a) {
    var found = false;
    for (var i = 0; i < b.length; i++) {
      if (!matched[i] && (b[i] - va).length <= eps) {
        matched[i] = true;
        found = true;
        break;
      }
    }
    if (!found) return false;
  }
  return true;
}

void main() {
  final rec = PatternRecognizer();

  // ===== 1. quadroring.dxf — эталон Python: вырожденный «массив» 1x1 =====
  final qr = DxfParser().parse(fx('quadroring.dxf'));
  final rdxf = rec.analyze(qr);
  expect(rdxf.isArray, 'quadroring.dxf: isArray=true (эталон Python)');
  expectEq(rdxf.count, 2, 'quadroring.dxf: count=2 (дубль эллипса)');
  expectEq(rdxf.rows, 1, 'quadroring.dxf: rows=1');
  expectEq(rdxf.cols, 1, 'quadroring.dxf: cols=1');
  expectNear(rdxf.stepX, 0.0, 'quadroring.dxf: stepX=0', eps: 1e-9);
  expectNear(rdxf.stepY, 0.0, 'quadroring.dxf: stepY=0', eps: 1e-9);
  expect(rdxf.gapX >= 0 && rdxf.gapY >= 0, 'quadroring.dxf: зазоры >= 0');
  expectEq(rdxf.offsets.length, 2, 'quadroring.dxf: 2 смещения');
  for (final o in rdxf.offsets) {
    expect(o.length < 1e-6, 'quadroring.dxf: смещение ~ (0,0)');
  }
  // Изоляция мастера: в буфер эллипса попадают ТОЛЬКО 2 эллипса, но не rect.
  expectEq(rdxf.masterPaths.length, 2, 'quadroring.dxf: мастер = 2 эллипса');
  expect(rdxf.masterPaths.every((p) => p.points.length > 300),
      'quadroring.dxf: мастер без прямоугольника (n=5)');
  expectNear(rdxf.labelW, 42.3971, 'quadroring.dxf: labelW', eps: 0.05);
  expectNear(rdxf.labelH, 43.7151, 'quadroring.dxf: labelH', eps: 0.05);
  expectNear(rdxf.masterArea, 1454.85, 'quadroring.dxf: masterArea', eps: 0.5);

  // ===== 2. quadroring.svg — тот же артворк: размер согласован с DXF =====
  final qs = SvgParser().parse(fx('quadroring.svg'));
  final rsvg = rec.analyze(qs);
  expect(rsvg.isArray, 'quadroring.svg: isArray=true (эталон Python)');
  expectEq(rsvg.count, 2, 'quadroring.svg: count=2');
  expectEq(rsvg.rows, 1, 'quadroring.svg: rows=1');
  expectEq(rsvg.cols, 1, 'quadroring.svg: cols=1');
  expect((rdxf.labelW - rsvg.labelW).abs() <= 0.5,
      'размер этикетки X согласован dxf/svg (0.5 мм)');
  expect((rdxf.labelH - rsvg.labelH).abs() <= 0.5,
      'размер этикетки Y согласован dxf/svg (0.5 мм)');
  expectNear(rsvg.labelW, 42.397, 'quadroring.svg: labelW', eps: 0.05);
  expectNear(rsvg.labelH, 43.715, 'quadroring.svg: labelH', eps: 0.05);
  expectNear(rsvg.masterArea, 1455.59, 'quadroring.svg: masterArea', eps: 0.5);
  expectEq(rsvg.masterPaths.length, 2, 'quadroring.svg: мастер = 2 эллипса');

  // ===== 3. quadroring.pdf — это артворк петли: одиночный контур =====
  final rpdf = rec.analyze(PdfParser().parse(fx('quadroring.pdf')));
  expect(!rpdf.isArray, 'quadroring.pdf: isArray=false (одиночная петля)');
  expectEq(rpdf.masterPaths.length, 1, 'quadroring.pdf: мастер = 1 контур');
  expect(rpdf.masterPaths[0].isClosed, 'quadroring.pdf: контур замкнут');
  expectEq(rpdf.count, 1, 'quadroring.pdf: count=1');
  expectEq(rpdf.rows, 1, 'quadroring.pdf: rows=1');
  expectEq(rpdf.cols, 1, 'quadroring.pdf: cols=1');
  expectNear(rpdf.labelW, 25.493, 'quadroring.pdf: labelW', eps: 0.05);
  expectNear(rpdf.labelH, 46.137, 'quadroring.pdf: labelH', eps: 0.05);
  expectNear(rpdf.masterArea, 797.12, 'quadroring.pdf: masterArea', eps: 0.5);

  // ===== 4. petlya.dxf — одиночный контур: массив не найден =====
  final pl = DxfParser().parse(fx('petlya.dxf'));
  final rpl = rec.analyze(pl);
  expect(!rpl.isArray, 'petlya.dxf: isArray=false (одиночный контур)');
  expectEq(rpl.masterPaths.length, 1, 'petlya.dxf: мастер = контур петли');
  expect(rpl.masterPaths[0].isClosed, 'petlya.dxf: мастер замкнут');
  expectEq(rpl.count, 1, 'petlya.dxf: count=1');
  expectEq(rpl.rows, 1, 'petlya.dxf: rows=1');
  expectEq(rpl.cols, 1, 'petlya.dxf: cols=1');
  expectNear(rpl.labelW, 25.493, 'petlya.dxf: labelW', eps: 0.05);
  expectNear(rpl.labelH, 46.137, 'petlya.dxf: labelH', eps: 0.05);
  expectNear(rpl.masterArea, 797.13, 'petlya.dxf: masterArea', eps: 0.5);
  expectEq(rpl.masterPaths[0].points.length, 2887,
      'petlya.dxf: контур 2887 точек (эталон парсера)');

  // petlya.svg — тоже одиночный контур (другой масштаб артворка).
  final rsv = rec.analyze(SvgParser().parse(fx('petlya.svg')));
  expect(!rsv.isArray, 'petlya.svg: isArray=false');
  expectEq(rsv.masterPaths.length, 1, 'petlya.svg: мастер = 1 контур');
  expectNear(rsv.labelW, 19.119, 'petlya.svg: labelW', eps: 0.05);
  expectNear(rsv.labelH, 34.601, 'petlya.svg: labelH', eps: 0.05);
  expectNear(rsv.masterArea, 448.33, 'petlya.svg: masterArea', eps: 0.5);

  // ===== 5. Синтетика: мастер 10x10, сетка 3 колонки x 2 ряда, шаг 20/15 ===
  final master = square(0, 0);
  final grid = <CamPath>[];
  for (var r = 0; r < 2; r++) {
    for (var c = 0; c < 3; c++) {
      grid.add(square(c * 20.0, -r * 15.0));
    }
  }
  final rsyn = rec.analyze(grid);
  expect(rsyn.isArray, 'синтетика: массив распознан');
  expectEq(rsyn.count, 6, 'синтетика: count=6');
  expectEq(rsyn.rows, 2, 'синтетика: rows=2');
  expectEq(rsyn.cols, 3, 'синтетика: cols=3');
  expectNear(rsyn.stepX, 20.0, 'синтетика: stepX=20', eps: 1e-9);
  expectNear(rsyn.stepY, 15.0, 'синтетика: stepY=15', eps: 1e-9);
  expectNear(rsyn.gapX, 10.0, 'синтетика: gapX=stepX-labelW=10', eps: 1e-9);
  expectNear(rsyn.gapY, 5.0, 'синтетика: gapY=stepY-labelH=5', eps: 1e-9);
  expectNear(rsyn.labelW, 10.0, 'синтетика: labelW=10', eps: 1e-9);
  expectNear(rsyn.labelH, 10.0, 'синтетика: labelH=10', eps: 1e-9);
  expectNear(rsyn.masterArea, 100.0, 'синтетика: masterArea=100', eps: 1e-9);
  expectEq(rsyn.masterPaths.length, 1, 'синтетика: мастер — один квадрат');
  expectEq(rsyn.masterPaths[0].points.length, 4, 'синтетика: 4 вершины мастера');
  expectNear(rsyn.masterPaths[0].points[0].x, 0.0, 'мастер в (0,0)', eps: 1e-9);
  final expOffsets = <Vec2>[
    const Vec2(0, 0), const Vec2(20, 0), const Vec2(40, 0),
    const Vec2(0, -15), const Vec2(20, -15), const Vec2(40, -15),
  ];
  expect(sameVecSet(rsyn.offsets, expOffsets), 'синтетика: смещения сетки 3x2');

  // ===== 6. generateArrayGrid: 2 колонки x 3 ряда =====
  final arr = generateArrayGrid([master],
      cols: 2, rows: 3, stepX: 20.0, stepY: 15.0);
  expectEq(arr.length, 6, 'generateArrayGrid: 6 копий');
  expect(arr.every((p) => p.isClosed), 'generateArrayGrid: замкнуты');
  expect(arr.every((p) => p.layerName == 'ARRAY'), 'generateArrayGrid: слой ARRAY');
  final expGridOffsets = <Vec2>[
    const Vec2(0, 0), const Vec2(0, -15), const Vec2(0, -30),
    const Vec2(20, 0), const Vec2(20, -15), const Vec2(20, -30),
  ];
  final gotOffsets = <Vec2>[];
  for (final p in arr) {
    final o = Vec2(p.points[0].x - master.points[0].x,
        p.points[0].y - master.points[0].y);
    gotOffsets.add(o);
  }
  expect(sameVecSet(gotOffsets, expGridOffsets),
      'generateArrayGrid: смещения (0,0),(20,0),(0,-15),(20,-15),(0,-30),(20,-30)');
  // Геометрия каждой копии — мастер, сдвинутый ровно на offset.
  for (final p in arr) {
    final o = Vec2(p.points[0].x - master.points[0].x,
        p.points[0].y - master.points[0].y);
    for (var i = 0; i < p.points.length; i++) {
      final expectPt = master.points[i] + o;
      expect((p.points[i] - expectPt).length < 1e-9,
          'generateArrayGrid: копия = мастер + offset');
    }
  }

  // ===== 7. multiplyPaths: клонирование мастера по смещениям =====
  final offs = <Vec2>[
    const Vec2(0, 0), const Vec2(20, 0), const Vec2(0, -15),
    const Vec2(20, -15), const Vec2(0, -30), const Vec2(20, -30),
  ];
  final mult = multiplyPaths([master], offs);
  expectEq(mult.length, 6, 'multiplyPaths: 1 мастер x 6 смещений = 6 путей');
  for (var k = 0; k < mult.length; k++) {
    final o = offs[k];
    expect(mult[k].isClosed, 'multiplyPaths: isClosed сохранён');
    expect(mult[k].layerName == 'ARRAY', 'multiplyPaths: слой ARRAY');
    expectEq(mult[k].points.length, master.points.length,
        'multiplyPaths: число точек как у мастера');
    for (var i = 0; i < master.points.length; i++) {
      final e = master.points[i] + o;
      expect((mult[k].points[i] - e).length < 1e-9,
          'multiplyPaths: копия сдвинута ровно на offset (k=$k)');
    }
  }
  // Два мастера x 2 смещения = 4 пути (порядок: offset снаружи, путь внутри).
  final lineMaster = CamPath(
      [const Vec2(0, 0), const Vec2(5, 5)], isClosed: false, layerName: 'X');
  final mult2 = multiplyPaths([master, lineMaster],
      [const Vec2(0, 0), const Vec2(30, -10)]);
  expectEq(mult2.length, 4, 'multiplyPaths: 2 мастера x 2 смещения');
  expectEq(mult2[3].points.length, 2, 'multiplyPaths: порядок offset-снаружи');
  expect(!mult2[3].isClosed, 'multiplyPaths: открытый путь остался открытым');
  expectNear(mult2[3].points[1].x, 35.0, 'multiplyPaths: сдвиг (30,-10)', eps: 1e-9);
  expectNear(mult2[3].points[1].y, -5.0, 'multiplyPaths: сдвиг (30,-10) y', eps: 1e-9);

  // ===== 8. autoRowsForRapport =====
  expectEq(autoRowsForRapport(304.8, 30, 3), 9, '304.8 / (30+3) = 9 рядов');
  expectEq(autoRowsForRapport(66, 30, 3), 2, '66 / 33 = 2');
  expectEq(autoRowsForRapport(33, 30, 3), 1, '33 / 33 = 1');
  expectEq(autoRowsForRapport(32, 30, 3), 0, 'меньше одного ряда -> 0');
  expectEq(autoRowsForRapport(0, 30, 3), 0, 'раппорт 0 -> 0');

  ok('pattern_recognition');
  // ignore: avoid_print
  print('Все тесты распознавания массивов и генератора сетки пройдены.');
}
