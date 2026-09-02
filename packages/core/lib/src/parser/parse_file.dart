/// Диспетчер разбора векторных файлов по расширению (порт
/// cam_material pipeline_helpers.py + cam_pipeline ai_parser.py).
///
/// Локально: .dxf, .svg, .pdf, .ai (если начинается с `%PDF` — как PDF,
/// иначе — серверная конвертация). .eps/.cdr/прочие — понятное русское
/// исключение «требуется серверная конвертация».
library;

import 'dart:io';

import 'base_parser.dart';
import 'parser_exception.dart';
import 'dxf_parser.dart';
import 'svg_parser.dart';
import 'pdf_parser.dart';
import 'ai_pdf_parser.dart';
import '../model/cam_path.dart';

/// Разобрать файл по расширению в список полилиний (мм, Y вверх).
List<CamPath> parseFile(String filePath) {
  final ext = filePath.toLowerCase();
  if (ext.endsWith('.dxf')) {
    return DxfParser().parse(filePath);
  }
  if (ext.endsWith('.svg')) {
    return SvgParser().parse(filePath);
  }
  if (ext.endsWith('.pdf')) {
    return PdfParser().parse(filePath);
  }
  if (ext.endsWith('.ai')) {
    return AiPdfParser().parse(filePath);
  }
  if (ext.endsWith('.eps')) {
    throw ParserException('Формат EPS: требуется серверная конвертация.');
  }
  if (ext.endsWith('.cdr')) {
    throw ParserException('Формат CDR: требуется серверная конвертация.');
  }
  final name = filePath.split(RegExp(r'[/\\]')).last;
  final dot = name.lastIndexOf('.');
  final fmt = dot > 0 ? name.substring(dot + 1).toUpperCase() : 'неизвестный';
  throw ParserException('Формат $fmt: требуется серверная конвертация.');
}

/// Узнать, PDF-совместим ли файл (для .ai), не читая целиком.
bool isPdfCompatible(String filePath) {
  try {
    final f = File(filePath);
    if (!f.existsSync()) return false;
    final raf = f.openSync();
    try {
      final head = raf.readSync(5);
      if (head.length < 5) return false;
      return String.fromCharCodes(head) == '%PDF-';
    } finally {
      raf.closeSync();
    }
  } catch (_) {
    return false;
  }
}
