/// Диспетчер разбора векторных байтов по имени/расширению (порт
/// cam_material pipeline_helpers.py + cam_pipeline ai_parser.py).
///
/// Локально: .dxf, .svg, .pdf, .ai (если начинается с `%PDF` — как PDF,
/// иначе — серверная конвертация). .eps/.cdr/прочие — понятное русское
/// исключение «требуется серверная конвертация».
///
/// Файловая система (dart:io) в этот модуль не входит — только байты;
/// чтение файлов по пути живёт в io-фасаде пакета (lib/io.dart).
library;

import 'dart:typed_data';

import 'parser_exception.dart';
import 'dxf_parser.dart';
import 'svg_parser.dart';
import 'pdf_parser.dart';
import 'ai_pdf_parser.dart';
import '../model/cam_path.dart';

/// Разобрать байты векторного файла в список полилиний (мм, Y вверх).
/// [name] — имя файла, по расширению выбирается парсер.
List<CamPath> parseBytes(Uint8List bytes, String name) {
  final ext = name.toLowerCase();
  if (ext.endsWith('.dxf')) {
    return DxfParser().parseBytes(bytes);
  }
  if (ext.endsWith('.svg')) {
    return SvgParser().parseBytes(bytes);
  }
  if (ext.endsWith('.pdf')) {
    return PdfParser().parseBytes(bytes);
  }
  if (ext.endsWith('.ai')) {
    return AiPdfParser().parseBytes(bytes);
  }
  if (ext.endsWith('.eps')) {
    throw ParserException('Формат EPS: требуется серверная конвертация.');
  }
  if (ext.endsWith('.cdr')) {
    throw ParserException('Формат CDR: требуется серверная конвертация.');
  }
  final base = name.split(RegExp(r'[/\\]')).last;
  final dot = base.lastIndexOf('.');
  final fmt = dot > 0 ? base.substring(dot + 1).toUpperCase() : 'неизвестный';
  throw ParserException('Формат $fmt: требуется серверная конвертация.');
}

/// PDF-совместим ли файл (для .ai) по первым байтам.
bool isPdfBytes(List<int> bytes) {
  if (bytes.length < 5) return false;
  return String.fromCharCodes(bytes.sublist(0, 5)) == '%PDF-';
}
