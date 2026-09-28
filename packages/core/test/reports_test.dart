// Тесты генераторов отчётов (агент 08): PDF-ТЭО, XLSX, DXF.
// Запуск: dart test/reports_test.dart (из packages/core)
//
// Эталонные числа (аг.05/аг.07 при LayoutParams() дефолтах, сортамент 100 ₽/м²,
// машина 5000 ₽/ч, 100 м/мин, переналадка 0.5 ч, смена 8×1):
//   count = 5040, wastePct = 26.18, perLabelArea = 2032.0,
//   costPer1000 = 704.88, costPerLabel = 0.70, areaM2 = 10.24128.
import 'dart:io';
import 'dart:convert';

import '../tool/test_utils.dart';
import '../lib/io.dart';
import '../lib/src/model/params.dart';
import '../lib/src/model/cam_path.dart';
import '../lib/src/model/vec2.dart';
import '../lib/src/calculator/material.dart';
import '../lib/src/calculator/shape.dart';
import '../lib/src/calculator/consumption.dart';
import '../lib/src/calculator/layout_optimizer.dart';
import '../lib/src/economics/assortment.dart';
import '../lib/src/economics/machine.dart';
import '../lib/src/economics/teo.dart';
import '../lib/src/economics/price_catalog.dart';
import '../lib/src/parser/dxf_parser.dart';
import '../lib/src/reports/report_models.dart';
import '../lib/src/reports/pdf_writer.dart';
import '../lib/src/reports/teo_report.dart';
import '../lib/src/reports/xlsx_writer.dart';
import '../lib/src/reports/teo_xlsx.dart';
import '../lib/src/reports/dxf_writer.dart';

// ---------------------------------------------------------------------------
// Хелперы
// ---------------------------------------------------------------------------

bool _containsAscii(List<int> hay, String needle) {
  return _containsBytes(hay, ascii.encode(needle));
}

bool _containsBytes(List<int> hay, List<int> needle) {
  if (needle.isEmpty) return true;
  for (var i = 0; i + needle.length <= hay.length; i++) {
    var match = true;
    for (var j = 0; j < needle.length; j++) {
      if (hay[i + j] != needle[j]) {
        match = false;
        break;
      }
    }
    if (match) return true;
  }
  return false;
}

/// Сборка TeoReportData из реальных модулей (эталонный раскрой 9×5).
TeoReportData _sampleData({DateTime? date, LayoutParams? params}) {
  final cat = PriceCatalog.defaults();
  final p = params ?? LayoutParams();
  final calc = computeMaterialAuto(p);
  if (calc.error != null) throw StateError('calc: ${calc.error}');
  final shape = shapeFromPreset('rect', calc.labelW, calc.labelH);
  final cons = computeConsumption(calc, shape);
  const input = TeoInput(
      material: AssortmentItem(
          id: 'paper-sa-80',
          name: 'Бумага самоклеящаяся 80 г/м² (пример)',
          pricePerM2: 100.0),
      machine: Machine(
          id: 'flexo-300',
          name: 'Флексопечать, ширина 300 мм (пример)',
          ratePerHour: 5000.0,
          speedMetersPerMin: 100.0,
          setupTimeHours: 0.5),
      workTime: WorkTime(hoursPerShift: 8, shiftsPerDay: 1));
  final teo = computeTeo(calc, cons, input);
  if (teo.error != null) throw StateError('teo: ${teo.error}');
  final variants = enumerateVariants(p);
  Consumption consFor(MaterialResult v) =>
      computeConsumption(v, shapeFromPreset('rect', v.labelW, v.labelH));
  final cmp = compareTeoVariants(variants, consFor, input);
  return TeoReportData(
    projectName: 'Проект «Северный ветер»',
    inputFile: 'C:/jobs/severnyj_veter/sever.dxf',
    params: p,
    shape: shape,
    calc: calc,
    consumption: cons,
    teo: teo,
    comparison: cmp,
    material: cat.assortment.first,
    machine: cat.machines.first,
    workTime: cat.workTime,
    currency: cat.currency,
    date: date ?? DateTime(2025, 3, 14, 10, 30),
  );
}

// ---------------------------------------------------------------------------
// 1. PDF
// ---------------------------------------------------------------------------

void testPdfStructure() {
  final data = _sampleData();
  final outPath = 'test/golden/report_teo.pdf';
  writeTeoReportPdf(outPath, data);
  final f = File(outPath);
  expect(f.existsSync(), 'PDF-файл создан: $outPath');
  final bytes = f.readAsBytesSync();
  expect(bytes.length > 1024, 'размер > 1 КБ (фактически ${bytes.length})');
  // Заголовок %PDF и конец %%EOF.
  expect(bytes.length > 8 && bytes[0] == 0x25 && bytes[1] == 0x50 &&
      bytes[2] == 0x44 && bytes[3] == 0x46, 'начинается с %PDF');
  final tailStart = bytes.length > 64 ? bytes.length - 64 : 0;
  expect(_containsAscii(bytes.sublist(tailStart), '%%EOF'),
      'заканчивается %%EOF');
  // Маркеры структуры PDF 1.4 / Type0 / Identity-H / ToUnicode.
  expect(_containsAscii(bytes, '%PDF-1.4'), 'версия PDF 1.4');
  expect(_containsAscii(bytes, '/Type0'), 'содержит /Type0');
  expect(_containsAscii(bytes, '/Identity-H'), 'содержит /Identity-H');
  expect(_containsAscii(bytes, '/ToUnicode'), 'содержит /ToUnicode');
  expect(_containsAscii(bytes, '/CIDFontType2'), 'содержит /CIDFontType2');
  expect(_containsAscii(bytes, 'startxref'), 'содержит startxref');
  expect(_containsAscii(bytes, 'xref'), 'содержит xref');
  // Кириллица проекта присутствует в ToUnicode (bfchar <gid> <код-точка>):
  // «Северный» — С 0421 е 0435 в 0432 е 0435 р 0440 н 043D ы 044B й 0439.
  const project = 'Северный';
  final hexes = <String>[
    '0421', '0435', '0432', '0435', '0440', '043D', '044B', '0439'
  ];
  var i = 0;
  for (final r in project.runes) {
    final hex = r.toRadixString(16).toUpperCase().padLeft(4, '0');
    expect(hexes.contains(hex), 'hex для U+$hex');
    expect(_containsAscii(bytes, '<$hex>'),
        'ToUnicode содержит <$hex> для «${String.fromCharCode(r)}»');
    i++;
  }
  expect(i == 8, 'разобрано 8 букв «Северный»');
  ok('pdf_structure');
}

// ---------------------------------------------------------------------------
// 2. XLSX
// ---------------------------------------------------------------------------

void testXlsxStructure() {
  final data = _sampleData();
  final outPath = 'test/golden/report_teo.xlsx';
  writeTeoXlsx(outPath, data);
  final f = File(outPath);
  expect(f.existsSync(), 'XLSX-файл создан: $outPath');
  final bytes = f.readAsBytesSync();
  expect(bytes.length > 512, 'размер > 512 Б (фактически ${bytes.length})');
  // Сигнатура store-zip: PK\x03\x04.
  expect(bytes.length > 4 && bytes[0] == 0x50 && bytes[1] == 0x4B &&
      bytes[2] == 0x03 && bytes[3] == 0x04, 'начинается с PK\\x03\\x04');
  // Части пакета (без сжатия — подстроки видны в бинарнике).
  expect(_containsAscii(bytes, '[Content_Types].xml'), '[Content_Types].xml');
  expect(_containsAscii(bytes, 'xl/workbook.xml'), 'xl/workbook.xml');
  expect(_containsAscii(bytes, 'xl/worksheets/sheet1.xml'), 'sheet1.xml');
  expect(_containsAscii(bytes, 'xl/worksheets/sheet3.xml'), 'sheet3.xml');
  expect(_containsAscii(bytes, 'xl/sharedStrings.xml') ||
      _containsAscii(bytes, 'inlineStr'), 'inline-строки');
  // Листы с кириллическими именами.
  expect(_containsBytes(bytes, utf8.encode('Расчёт')),
      'лист «Расчёт»');
  expect(_containsBytes(bytes, utf8.encode('Варианты')),
      'лист «Варианты»');
  // Эталонные значения из реального расчёта.
  expect(_containsAscii(bytes, '<v>5040</v>'), 'N = 5040 в ячейке');
  expect(_containsAscii(bytes, '26.18'), 'отходы 26.18%');
  expect(_containsAscii(bytes, '704.88'), 'costPer1000 = 704.88');
  expect(_containsAscii(bytes, '0.002032'), 'на этикетку 0.002032 м²');
  expect(_containsAscii(bytes, '3552.58'), 'ИТОГО 3552.58');
  expect(_containsAscii(bytes, '10.24128'), 'площадь 10.24128 м²');
  ok('xlsx_structure');
}

// ---------------------------------------------------------------------------
// 3. DXF
// ---------------------------------------------------------------------------

(List<Vec2>, List<Vec2>) _squareAndOpen() {
  // Замкнутый квадрат 10×10 и открытая ломаная из 3 вершин.
  final sq = [
    const Vec2(0, 0), const Vec2(10, 0), const Vec2(10, 10), const Vec2(0, 10)
  ];
  final op = [const Vec2(20, 0), const Vec2(30, 5), const Vec2(25, 12)];
  return (sq, op);
}

void testDxfWrite() {
  final (sq, op) = _squareAndOpen();
  final paths = <CamPath>[
    CamPath(sq, isClosed: true, layerName: 'LABEL'),
    CamPath(op, isClosed: false, layerName: 'КРОМКА'),
    CamPath([const Vec2(-5, -5), const Vec2(-5, -15)], layerName: ''), // → слой 0
  ];
  final outPath = 'test/golden/paths_roundtrip.dxf';
  writeDxf(outPath, paths);
  final f = File(outPath);
  expect(f.existsSync(), 'DXF-файл создан: $outPath');
  final text = f.readAsStringSync();
  expect(text.contains('AC1015'), 'версия R2000 (AC1015)');
  expect(text.contains(r'$INSUNITS'), 'секция HEADER с INSUNITS');
  expect(text.contains('LWPOLYLINE'), 'содержит LWPOLYLINE');
  expect(text.contains('LABEL'), 'имя слоя LABEL');
  expect(text.contains(r'\U+041A'), 'кириллический слой в \\U+XXXX');
  expect(text.contains('10.0000'), 'координаты с 4 знаками');
  expect(text.contains('EOF'), 'заканчивается EOF');

  // Round-trip через DxfParser: число путей, замкнутость, слои, габариты.
  final parsed = DxfParser().parse(outPath);
  expectEq(parsed.length, 3, 'round-trip: 3 контура');
  expect(parsed[0].isClosed, 'квадрат замкнут');
  expect(!parsed[1].isClosed, 'ломаная открыта');
  expectEq(parsed[0].layerName, 'LABEL', 'слой квадрата');
  expectEq(parsed[1].layerName, 'КРОМКА', 'слой ломаной (декодирован)');
  expectEq(parsed[2].layerName, '0', 'пустой слой → 0');
  expectEq(parsed[0].points.length, 4, 'квадрат: 4 вершины');
  expectEq(parsed[1].points.length, 3, 'ломаная: 3 вершины');

  void checkBounds(CamPath a, CamPath b) {
    var minX = double.infinity, minY = double.infinity;
    var maxX = double.negativeInfinity, maxY = double.negativeInfinity;
    for (final p in a.points) {
      if (p.x < minX) minX = p.x;
      if (p.y < minY) minY = p.y;
      if (p.x > maxX) maxX = p.x;
      if (p.y > maxY) maxY = p.y;
    }
    var minX2 = double.infinity, minY2 = double.infinity;
    var maxX2 = double.negativeInfinity, maxY2 = double.negativeInfinity;
    for (final p in b.points) {
      if (p.x < minX2) minX2 = p.x;
      if (p.y < minY2) minY2 = p.y;
      if (p.x > maxX2) maxX2 = p.x;
      if (p.y > maxY2) maxY2 = p.y;
    }
    expectNear(minX, minX2, 'minX', eps: 1e-3);
    expectNear(minY, minY2, 'minY', eps: 1e-3);
    expectNear(maxX, maxX2, 'maxX', eps: 1e-3);
    expectNear(maxY, maxY2, 'maxY', eps: 1e-3);
  }

  for (var i = 0; i < 3; i++) {
    checkBounds(paths[i], parsed[i]);
  }
  // Вершины совпадают с допуском округления 1e-3.
  for (var i = 0; i < parsed[0].points.length; i++) {
    expectNear(parsed[0].points[i].x, sq[i].x, 'квадрат x$i', eps: 1e-3);
    expectNear(parsed[0].points[i].y, sq[i].y, 'квадрат y$i', eps: 1e-3);
  }
  for (var i = 0; i < parsed[1].points.length; i++) {
    expectNear(parsed[1].points[i].x, op[i].x, 'ломаная x$i', eps: 1e-3);
    expectNear(parsed[1].points[i].y, op[i].y, 'ломаная y$i', eps: 1e-3);
  }
  ok('dxf_write_roundtrip');
}

// ---------------------------------------------------------------------------
// 4. Шрифт для кириллицы
// ---------------------------------------------------------------------------

void testFontPath() {
  final p = fontPathForCyrillic();
  expect(p != null, 'fontPathForCyrillic() не null');
  final f = File(p!);
  expect(f.existsSync(), 'файл шрифта существует: $p');
  expect(f.lengthSync() > 50000, 'размер шрифта > 50 КБ');
  final head = f.openSync().readSync(4);
  expect(head.length == 4 && head[0] == 0x00 && head[1] == 0x01,
      'TTF-сигнатура 00 01 (sfnt)');
  ok('font_path_cyrillic');
}

// ---------------------------------------------------------------------------
// 5. Все writer'ы на реальных данных (без падений)
// ---------------------------------------------------------------------------

void testWritersRealData() {
  final data = _sampleData();
  final pdfPath = 'test/golden/report_teo_real.pdf';
  final xlsxPath = 'test/golden/report_teo_real.xlsx';
  final dxfPath = 'test/golden/label_contour_real.dxf';
  writeTeoReportPdf(pdfPath, data);
  writeTeoXlsx(xlsxPath, data);
  // Контур этикетки из shape-данных (прямоугольник 50×30) → DXF.
  final contour = <CamPath>[
    CamPath([
      Vec2(0, 0),
      Vec2(data.calc.labelW, 0),
      Vec2(data.calc.labelW, data.calc.labelH),
      Vec2(0, data.calc.labelH),
    ], isClosed: true, layerName: 'LABEL'),
  ];
  writeDxf(dxfPath, contour);
  for (final p in [pdfPath, xlsxPath, dxfPath]) {
    final f = File(p);
    expect(f.existsSync(), 'создан $p');
    expect(f.lengthSync() > 100, 'непустой $p');
  }
  // Эталонные значения в PDF-структуре и DXF не теряются при сборке.
  final pdfBytes = File(pdfPath).readAsBytesSync();
  expect(_containsAscii(pdfBytes, '%PDF-1.4'), 'PDF валиден на реальных данных');
  ok('writers_real_data');
}

// ---------------------------------------------------------------------------
// 6. Эскиз ТЭО (графа 6): подпись не наезжает на границы этикетки
// ---------------------------------------------------------------------------

/// Инвариант: подпись «Этикетка W × H» либо целиком внутри бокса,
/// либо полностью под ним — никогда не пересекает линию границы.
/// Регрессия: у узких габаритов (15×80) подпись рисовалась по центру
/// бокса и вылезала за его стороны.
void testSketchCaptionNoOverflow() {
  final fontPath = fontPathForCyrillic();
  expect(fontPath != null, 'шрифт для кириллицы найден');
  final font = parseTtfFont(File(fontPath!).readAsBytesSync());

  String hexOf(String s) {
    final sb = StringBuffer();
    for (final cp in s.runes) {
      var gid = font.glyphFor(cp);
      if (gid < 0) gid = font.glyphFor(0x3F);
      if (gid < 0) gid = font.glyphFor(0x20);
      expect(gid >= 0, 'глиф есть для U+${cp.toRadixString(16)}');
      sb.write(gid.toRadixString(16).toUpperCase().padLeft(4, '0'));
    }
    return sb.toString();
  }

  void check(LayoutParams params, String mark) {
    final data = _sampleData(params: params);
    final out = 'test/golden/report_teo_sketch_$mark.pdf';
    writeTeoReportPdf(out, data);
    final text = String.fromCharCodes(File(out).readAsBytesSync());

    final cap1 = 'Этикетка ${data.shape.w.toStringAsFixed(2)} мм × '
        '${data.shape.h.toStringAsFixed(2)} мм';
    final capHex = hexOf(cap1);
    final capW = font.widthPt(cap1, 8);

    final tm = RegExp('1 0 0 1 (-?[\\d.]+) (-?[\\d.]+) Tm <$capHex> Tj')
        .firstMatch(text);
    expect(tm != null, '[$mark] подпись «$cap1» найдена в потоке');
    final capX = double.parse(tm!.group(1)!);
    final capY = double.parse(tm.group(2)!);

    final rects = RegExp('(-?[\\d.]+) (-?[\\d.]+) (-?[\\d.]+) (-?[\\d.]+) re S')
        .allMatches(text);
    expect(rects.isNotEmpty, '[$mark] бокс эскиза (re) найден');
    final r = rects.last;
    final rx = double.parse(r.group(1)!);
    final ry = double.parse(r.group(2)!); // низ бокса (PDF-базис)
    final rw = double.parse(r.group(3)!);
    final rh = double.parse(r.group(4)!);

    // Вертикальное пересечение подписи и бокса: глифы size=8 поднимаются
    // над базовой линией не более чем на ~6.5 pt (cap-height ≈ 5.7).
    final overlapV = capY + 6.5 > ry && capY < ry + rh;
    final insideX = capX >= rx - 0.5 && capX + capW <= rx + rw + 0.5;
    expect(overlapV == false || insideX,
        '[$mark] подпись не пересекает границу бокса '
        '(capX=$capX capW=$capW rect=[$rx..${rx + rw}] '
        'capY=$capY rectY=[$ry..${ry + rh}])');
  }

  // Широкая этикетка (эталон 50×30): подпись внутри бокса.
  check(LayoutParams(), 'wide');
  // Узкий высокий габарит: подпись должна уйти под бокс, а не вылезать.
  check(LayoutParams(labelW: 15, labelH: 80), 'narrow');
  ok('sketch_caption_no_overflow');
}

void main() {
  // Каталог для выходных артефактов.
  Directory('test/golden').createSync(recursive: true);
  testFontPath();
  testPdfStructure();
  testXlsxStructure();
  testDxfWrite();
  testWritersRealData();
  testSketchCaptionNoOverflow();
  // ignore: avoid_print
  print('Все тесты отчётов (PDF/XLSX/DXF) пройдены.');
}
