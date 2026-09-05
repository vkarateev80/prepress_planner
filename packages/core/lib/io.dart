/// IO-фасад пакета «Препресс-Планер» (ядро): функции, которым нужна файловая
/// система (dart:io). НЕ экспортируется чистым барелем [prepress_core.dart] —
/// этот файл импортируется только на VM/desktop (в браузере dart:io нет).
///
/// Здесь живут прежние «путевые» API поверх чистых байтовых функций ядра:
///   parseFile(path)                → parseBytes(байты, path) + isPdfBytes
///   writeTeoReportPdf(out, data)   → buildTeoReportPdf + системный шрифт
///   writeTeoXlsx(out, data)        → buildTeoXlsx + запись файла
///   writeDxf(out, paths)           → buildDxfText + запись файла
///   fontPathForCyrillic()          → поиск TTF (Windows/Linux/рядом)
library;

import 'dart:io';
import 'dart:typed_data';

// ВАЖНО: только относительные импорты src/… (не package:-барель). VM считает
// библиотеку, импортированную package:-URI и относительным file:-URI из тестов,
// РАЗНЫМИ (две копии классов/исключений). Относительные пути сводятся к одному
// каноническому файлу — классы и ParserException совпадают с тестами и тулами.
import 'src/model/cam_path.dart';
import 'src/parser/parser_exception.dart';
import 'src/parser/parse_file.dart';
import 'src/parser/dxf_parser.dart';
import 'src/parser/svg_parser.dart';
import 'src/parser/pdf_parser.dart';
import 'src/parser/ai_pdf_parser.dart';
import 'src/reports/report_models.dart';
import 'src/reports/teo_report.dart';
import 'src/reports/teo_xlsx.dart';
import 'src/reports/dxf_writer.dart';

// ============================================================
// Разбор файлов по пути
// ============================================================

/// Разобрать файл по расширению в список полилиний (мм, Y вверх).
List<CamPath> parseFile(String filePath) {
  final f = File(filePath);
  if (!f.existsSync()) {
    throw ParserException('Файл не найден: $filePath');
  }
  late Uint8List bytes;
  try {
    bytes = f.readAsBytesSync();
  } catch (e) {
    throw ParserException('Ошибка при чтении файла: $e');
  }
  return parseBytes(bytes, filePath);
}

/// PDF-совместим ли файл (для .ai), не читая целиком.
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

// ============================================================
// Поиск TTF с кириллицей
// ============================================================

/// Возвращает путь к TTF-шрифту с кириллицей либо null.
/// Порядок поиска: arial.ttf (Windows), затем DejaVuSans.ttf — в системных
/// каталогах, в каталоге пользователя Windows и рядом с проектом.
String? fontPathForCyrillic() {
  const system = r'C:\Windows\Fonts';
  final candidates = <String>[
    '$system\\arial.ttf',
    '$system\\DejaVuSans.ttf',
    '$system\\dejavusans.ttf',
  ];
  // Каталог шрифтов пользователя (Windows 10+): раскрываем %LOCALAPPDATA%.
  final localAppData = Platform.environment['LOCALAPPDATA'];
  if (localAppData != null && localAppData.isNotEmpty) {
    candidates.add('$localAppData\\Microsoft\\Windows\\Fonts\\DejaVuSans.ttf');
    candidates.add('$localAppData\\Microsoft\\Windows\\Fonts\\dejavusans.ttf');
  }
  for (final c in candidates) {
    try {
      if (File(c).existsSync()) return c;
    } catch (_) {/* путь невалиден — пропускаем */}
  }

  // «Рядом с проектом»: ограниченный обход текущего дерева (глубина 4,
  // без venv/node_modules) в поисках DejaVuSans.ttf / arial.ttf.
  const depthLimit = 4;
  final hits = <String>[];
  void walk(Directory dir, int depth) {
    if (depth > depthLimit || hits.isNotEmpty) return;
    List<FileSystemEntity> entries;
    try {
      entries = dir.listSync(followLinks: false);
    } catch (_) {
      return;
    }
    for (final e in entries) {
      if (e is Directory) {
        final n = e.path.split(Platform.pathSeparator).last.toLowerCase();
        if (n == 'venv' || n == 'node_modules' || n == '.git' ||
            n == 'build' || n == '.dart_tool') {
          continue;
        }
        walk(e, depth + 1);
      } else if (e is File) {
        final n = e.path.split(Platform.pathSeparator).last.toLowerCase();
        if (n == 'dejavusans.ttf' || n == 'arial.ttf') {
          hits.add(e.path);
        }
      }
      if (hits.isNotEmpty) return;
    }
  }

  walk(Directory.current, 0);
  if (hits.isNotEmpty) return hits.first;
  return null;
}

/// Байты кириллического TTF (системный поиск) либо null.
Uint8List? loadCyrillicFontBytes() {
  final path = fontPathForCyrillic();
  if (path == null) return null;
  return File(path).readAsBytesSync();
}

// ============================================================
// Отчёты: запись на диск (байты строят чистые функции ядра)
// ============================================================

/// Пишет PDF-отчёт ТЭО (русский, A4).
void writeTeoReportPdf(String outPath, TeoReportData data) {
  final fontBytes = loadCyrillicFontBytes();
  if (fontBytes == null) {
    throw StateError('Не найден TTF-шрифт с кириллицей '
        '(arial.ttf/DejaVuSans.ttf) для PDF-отчёта');
  }
  File(outPath).writeAsBytesSync(buildTeoReportPdf(data, fontBytes));
}

/// Пишет книгу XLSX отчёта ТЭО.
void writeTeoXlsx(String outPath, TeoReportData data) {
  File(outPath).writeAsBytesSync(buildTeoXlsx(data));
}

/// Пишет DXF-файл с путями [paths] (каждый — LWPOLYLINE на своём слое).
void writeDxf(String outPath, List<CamPath> paths,
    {String version = 'AC1015'}) {
  File(outPath).writeAsStringSync(buildDxfText(paths, version: version));
}

// ============================================================
// VM-расширения: прежний API `parser.parse(path)` поверх parseFile
// (удобно тестам и инструментам; в web-сборку io.dart не попадает)
// ============================================================

extension DxfParserIo on DxfParser {
  List<CamPath> parse(String filePath) => parseFile(filePath);
}

extension SvgParserIo on SvgParser {
  List<CamPath> parse(String filePath) => parseFile(filePath);
}

extension PdfParserIo on PdfParser {
  List<CamPath> parse(String filePath) => parseFile(filePath);
}

extension AiPdfParserIo on AiPdfParser {
  List<CamPath> parse(String filePath) => parseFile(filePath);
}
