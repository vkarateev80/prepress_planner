/// Парсер Adobe Illustrator (.ai).
///
/// Локально поддерживается только AI с PDF-совместимостью (файл начинается
/// с `%PDF`): в этом случае поток разбирается как PDF. Если файл не
/// PDF-совместим (Illustrator без галочки «Create PDF Compatible File»),
/// выбрасывается ParserException с русским текстом о серверной конвертации
/// (порт cam_pipeline ai_parser.py: попытка 1 — PDF-поток, дальше движки).
library;

import 'base_parser.dart';
import 'parser_exception.dart';
import 'pdf_parser.dart';
import 'parse_file.dart';
import '../model/cam_path.dart';

class AiPdfParser extends BaseParser {
  @override
  List<CamPath> parse(String filePath) {
    if (isPdfCompatible(filePath)) {
      return PdfParser().parse(filePath);
    }
    throw ParserException(
        'AI без PDF-совместимости: требуется серверная конвертация.');
  }
}
