// Тесты диспетчера parseFile + AI-парсера (контракт аг.02).
import '../tool/test_utils.dart';
import '../lib/src/parser/parse_file.dart';
import '../lib/src/parser/ai_pdf_parser.dart';
import '../lib/src/parser/parser_exception.dart';
import '../lib/src/model/cam_path.dart';

String fx(String name) => '../../fixtures/$name';

void main() {
  // .dxf → DxfParser (3 контура quadroring).
  final qrDxf = parseFile(fx('quadroring.dxf'));
  expectEq(qrDxf.length, 3, 'parseFile .dxf: 3 контура');
  expect(qrDxf.every((p) => p.isClosed), 'parseFile .dxf: все замкнуты');
  ok('parseFile .dxf');

  // .svg → SvgParser.
  final qrSvg = parseFile(fx('quadroring.svg'));
  expect(qrSvg.isNotEmpty, 'parseFile .svg: непусто');
  ok('parseFile .svg');

  // .pdf → PdfParser.
  final qrPdf = parseFile(fx('quadroring.pdf'));
  expect(qrPdf.isNotEmpty, 'parseFile .pdf: непусто');
  ok('parseFile .pdf');

  // .ai PDF-совместимый → читается как PDF.
  final ai = parseFile(fx('quadroring.ai'));
  expect(ai.isNotEmpty, 'parseFile .ai (PDF-совместимый): непусто');
  expect(ai.every((p) => p.points.isNotEmpty), '.ai: точки есть');
  ok('parseFile .ai PDF-совместимый');

  // .cdr / .eps → ParserException с русским текстом «серверная конвертация».
  for (final ext in ['.cdr', '.eps']) {
    var threw = false;
    var msg = '';
    try {
      parseFile(fx('quadroring$ext'));
    } on ParserException catch (e) {
      threw = true;
      msg = e.message;
    }
    expect(threw, 'parseFile $ext: ParserException');
    expect(msg.contains('серверная конвертация'), '$ext: сообщение о конвертации: "$msg"');
  }
  ok('parseFile .cdr/.eps → ParserException');

  // Неизвестный формат → ParserException.
  var threwUnknown = false;
  try {
    parseFile(fx('quadroring.zzz'));
  } on ParserException {
    threwUnknown = true;
  }
  expect(threwUnknown, 'parseFile неизвестного формата: ParserException');
  ok('parseFile неизвестный формат');

  // AiPdfParser: PDF-совместимый .ai — парсится; isPdfCompatible работает.
  expect(isPdfCompatible(fx('quadroring.ai')), 'quadroring.ai — PDF-совместим');
  expect(!isPdfCompatible(fx('quadroring.dxf')), 'quadroring.dxf — не PDF');
  ok('isPdfCompatible');
}
