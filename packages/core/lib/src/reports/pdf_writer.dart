/// Низкоуровневый генератор PDF 1.4 (только stdlib) с внедрением TTF.
///
/// Кириллица реализована честным способом: TTF внедряется целиком как
/// FontFile2, шрифт объявляется Type0/CIDFontType2 с кодировкой Identity-H,
/// а в потоке контента каждый символ кодируется ДВУМЯ БАЙТАМИ = id глифа из
/// cmap (Identity-H: код = CID = GID при /CIDToGIDMap /Identity).
/// Для извлечения текста добавляется /ToUnicode CMap (bfchar: gid → Unicode).
///
/// Текстовые строки пишутся как hex-строки <....>, поэтому экранирование
/// скобок/обратных слэшей не требуется вовсе.
library;

import 'dart:convert';
import 'dart:typed_data';
import 'dart:math' as math;

// ============================================================
// Парсинг TTF: таблицы head/hhea/maxp/hmtx/cmap
// ============================================================

int _u16(List<int> b, int off) => (b[off] << 8) | b[off + 1];
int _i16(List<int> b, int off) {
  final v = _u16(b, off);
  return v >= 0x8000 ? v - 0x10000 : v;
}

int _u32(List<int> b, int off) =>
    (b[off] << 24) | (b[off + 1] << 16) | (b[off + 2] << 8) | b[off + 3];

/// Разобранный TTF: метрики и cmap для кодирования Identity-H.
class TtfFont {
  final Uint8List file;
  final String name;
  final int unitsPerEm;
  final int numGlyphs;
  final int ascent; // hhea.ascender, ед. шрифта
  final int descent; // hhea.descender (отрицательный), ед. шрифта
  final int capHeight; // OS/2 sCapHeight (или ascent)
  final int bboxXMin, bboxYMin, bboxXMax, bboxYMax;
  final List<int> _advance; // ширина глифа, ед. шрифта [numGlyphs]
  final List<int> _glyphOfCp; // кодовая точка BMP → gid; -1 = нет глифа

  TtfFont._(this.file, this.name, this.unitsPerEm, this.numGlyphs,
      this.ascent, this.descent, this.capHeight, this.bboxXMin, this.bboxYMin,
      this.bboxXMax, this.bboxYMax, this._advance, this._glyphOfCp);

  /// Глиф для кодовой точки BMP; -1 — глифа нет.
  int glyphFor(int codePoint) =>
      (codePoint >= 0 && codePoint <= 0xFFFF) ? _glyphOfCp[codePoint] : -1;

  /// Продвижение глифа, ед. шрифта.
  int advanceOfGlyph(int gid) =>
      (gid >= 0 && gid < _advance.length) ? _advance[gid] : 0;

  /// Ширина текста в pt при заданном кегле (для вёрстки отчёта).
  double widthPt(String text, double size) {
    var units = 0.0;
    for (final cp in text.runes) {
      final gid = glyphFor(cp);
      if (gid < 0) continue;
      units += advanceOfGlyph(gid).toDouble();
    }
    return units * size / unitsPerEm;
  }
}

/// Разбор TTF. Требуются таблицы head, hhea, maxp, hmtx, cmap.
/// Возвращает метрики и карту «кодовая точка BMP → glyph id»
/// (cmap format 4; при наличии только format 12 — через него).
TtfFont parseTtfFont(List<int> bytes, {String name = 'EmbeddedFont'}) {
  if (bytes.length < 12 || bytes.length > 1 << 30) {
    throw FormatException('Не похоже на TTF-файл (мал/велик размер).');
  }
  final magic = _u32(bytes, 0);
  if (magic != 0x00010000 && magic != 0x74727565 /*'true'*/) {
    throw FormatException('Не TTF: сигнатура 0x${magic.toRadixString(16)}.');
  }
  final numTables = _u16(bytes, 4);
  final tables = <String, (int, int)>{};
  for (var i = 0; i < numTables; i++) {
    final rec = 12 + 16 * i;
    if (rec + 16 > bytes.length) break;
    final tag = ascii.decode(bytes.sublist(rec, rec + 4), allowInvalid: true);
    tables[tag] = (_u32(bytes, rec + 8), _u32(bytes, rec + 12));
  }
  (int, int)? table(String tag) => tables[tag];

  final head = table('head');
  final hhea = table('hhea');
  final maxp = table('maxp');
  final hmtx = table('hmtx');
  final cmap = table('cmap');
  if (head == null || hhea == null || maxp == null ||
      hmtx == null || cmap == null) {
    throw FormatException(
        'TTF без нужных таблиц (head/hhea/maxp/hmtx/cmap) — не поддерживается.');
  }

  final unitsPerEm = _u16(bytes, head.$1 + 18);
  if (unitsPerEm <= 0) {
    throw FormatException('TTF: unitsPerEm <= 0.');
  }
  final numGlyphs = _u16(bytes, maxp.$1 + 4);
  final numberOfHMetrics = _u16(bytes, hhea.$1 + 34);
  if (numGlyphs <= 0 || numberOfHMetrics <= 0) {
    throw FormatException('TTF: пустые hhea/maxp.');
  }

  // --- hmtx: продвижения.
  final advance = List<int>.filled(numGlyphs, 0);
  var lastAdvance = 0;
  for (var g = 0; g < numGlyphs; g++) {
    final idx = g < numberOfHMetrics ? g : numberOfHMetrics - 1;
    final off = hmtx.$1 + 4 * idx;
    lastAdvance = (off + 2 <= hmtx.$1 + hmtx.$2) ? _u16(bytes, off) : 0;
    advance[g] = lastAdvance;
  }

  // --- cmap: выбираем подтаблицу и строим карту BMP.
  final glyphOfCp = List<int>.filled(0x10000, -1);
  final cmapVersion = _u16(bytes, cmap.$1);
  final cmapNum = _u16(bytes, cmap.$1 + 2);
  int? subOff;
  for (var i = 0; i < cmapNum; i++) {
    final rec = cmap.$1 + 4 + 8 * i;
    if (rec + 8 > bytes.length) break;
    final plat = _u16(bytes, rec);
    final enc = _u16(bytes, rec + 2);
    if ((plat == 3 && enc == 1) || (plat == 0 && enc == 3)) {
      subOff = _u32(bytes, rec + 4); // Windows BMP / Unicode BMP
      break;
    }
  }
  if (subOff == null) {
    // fallback: Windows UCS-4 (format 12)
    for (var i = 0; i < cmapNum; i++) {
      final rec = cmap.$1 + 4 + 8 * i;
      final plat = _u16(bytes, rec);
      final enc = _u16(bytes, rec + 2);
      if ((plat == 3 && enc == 10) || (plat == 0 && enc == 4)) {
        subOff = _u32(bytes, rec + 4);
        break;
      }
    }
  }
  if (subOff == null) {
    throw FormatException('TTF: подходящая cmap-подтаблица не найдена.');
  }
  final cmapOff = cmap.$1 + subOff;
  if (cmapOff + 2 > bytes.length) {
    throw FormatException('TTF: cmap за пределами файла.');
  }
  final fmt = _u16(bytes, cmapOff);
  if (fmt == 4) {
    _parseCmapFormat4(bytes, cmapOff, glyphOfCp);
  } else if (fmt == 12) {
    _parseCmapFormat12(bytes, cmapOff, glyphOfCp);
  } else {
    throw FormatException(
        'TTF: cmap format $fmt не поддерживается (нужен 4 или 12).');
  }

  // --- Метрики строк.
  final ascent = _i16(bytes, hhea.$1 + 4);
  final descent = _i16(bytes, hhea.$1 + 6);
  final bboxXMin = _i16(bytes, head.$1 + 36);
  final bboxYMin = _i16(bytes, head.$1 + 38);
  final bboxXMax = _i16(bytes, head.$1 + 40);
  final bboxYMax = _i16(bytes, head.$1 + 42);

  // --- OS/2: CapHeight (version >= 2).
  var capHeight = ascent;
  final os2 = table('OS/2');
  if (os2 != null) {
    final v = _u16(bytes, os2.$1);
    if (v >= 2 && os2.$1 + 90 <= bytes.length) {
      capHeight = _u16(bytes, os2.$1 + 88);
    }
  }

  return TtfFont._(
    Uint8List.fromList(bytes),
    name,
    unitsPerEm,
    numGlyphs,
    ascent,
    descent,
    capHeight,
    bboxXMin,
    bboxYMin,
    bboxXMax,
    bboxYMax,
    advance,
    glyphOfCp,
  );
}

/// cmap format 4: сегменты BMP.
void _parseCmapFormat4(List<int> b, int off, List<int> glyphOfCp) {
  final segCountX2 = _u16(b, off + 6);
  final segCount = segCountX2 ~/ 2;
  final endCodes = off + 14;
  final startCodes = endCodes + segCountX2 + 2; // + reservedPad
  final idDeltas = startCodes + segCountX2;
  final idRangeOffsets = idDeltas + segCountX2;
  final glyphIdArray = idRangeOffsets + segCountX2;
  for (var s = 0; s < segCount; s++) {
    final end = _u16(b, endCodes + 2 * s);
    final start = _u16(b, startCodes + 2 * s);
    final delta = _u16(b, idDeltas + 2 * s);
    final rangeOff = _u16(b, idRangeOffsets + 2 * s);
    for (var c = start; c <= end && c <= 0xFFFF; c++) {
      int gid;
      if (rangeOff == 0) {
        gid = (c + delta) & 0xFFFF;
      } else {
        // Адрес — от позиции idRangeOffset[s] в 16-битных словах.
        final wordIdx = (rangeOff ~/ 2) + (c - start) + s;
        final addr = idRangeOffsets + 2 * wordIdx;
        if (addr + 2 > b.length) continue;
        gid = _u16(b, addr);
        if (gid != 0) gid = (gid + delta) & 0xFFFF;
      }
      glyphOfCp[c] = gid;
    }
  }
}

/// cmap format 12: группы (startCharCode, endCharCode, startGlyphID).
void _parseCmapFormat12(List<int> b, int off, List<int> glyphOfCp) {
  final nGroups = _u32(b, off + 12);
  for (var i = 0; i < nGroups; i++) {
    final g = off + 16 + 12 * i;
    if (g + 12 > b.length) break;
    final s = _u32(b, g);
    final e = _u32(b, g + 4);
    final startGid = _u32(b, g + 8);
    final end = math.min(e, 0xFFFF);
    for (var c = s; c <= end; c++) {
      glyphOfCp[c] = startGid + (c - s);
    }
  }
}

// ============================================================
// PDF-документ
// ============================================================

class _Late {
  final Uint8List Function() build;
  _Late(this.build);
}

/// Число для PDF: целое без десятичной точки, иначе 2 знака.
String _pdfNum(double v) {
  if (v == v.roundToDouble() && v.abs() < 1e12) return v.toInt().toString();
  return v.toStringAsFixed(2);
}

/// Документ PDF: шрифт (F1) внедряется при создании; страницы добавляются
/// через [newPage] и рисуются холстом [PdfCanvas].
class PdfDocument {
  final TtfFont font;
  final double pageWidth;
  final double pageHeight;

  // Тела объектов: bodies[n] — тело объекта с номером n (bodies[0] не используется).
  final List<Object> _bodies = <Object>[Uint8List(0)];
  final List<PdfCanvas> _pages = [];
  final Map<int, int> _gidToCp = {}; // gid → кодовая точка (для ToUnicode)

  late final int fontFile2Obj;
  late final int fontDescriptorObj;
  late final int cidFontObj;
  late final int toUnicodeObj;
  late final int type0FontObj;

  PdfDocument(this.font, {this.pageWidth = 595, this.pageHeight = 842}) {
    fontFile2Obj = _addStream(font.file, extra: ' /Length1 ${font.file.length}');
    fontDescriptorObj = _addAscii(_descriptorBody());
    cidFontObj = _addAscii(_cidFontBody());
    // ToUnicode — ПОТОК, контент известен только после отрисовки текста.
    toUnicodeObj = _addLateStream(() => _toUnicodeBody());
    type0FontObj = _addAscii(_type0Body());
  }

  int _addAscii(String s) {
    _bodies.add(ascii.encode(s));
    return _bodies.length - 1;
  }

  int _addLateStream(Uint8List Function() f) {
    _bodies.add(_Late(() {
      final data = f();
      final bb = BytesBuilder();
      bb.add(ascii.encode('<< /Length ${data.length} >>\nstream\n'));
      bb.add(data);
      bb.add(ascii.encode('\nendstream'));
      return bb.toBytes();
    }));
    return _bodies.length - 1;
  }

  int _addStream(Uint8List data, {String extra = ''}) {
    final head = ascii.encode('<< /Length ${data.length}$extra >>\nstream\n');
    final tail = ascii.encode('\nendstream');
    final bb = BytesBuilder();
    bb.add(head);
    bb.add(data);
    bb.add(tail);
    _bodies.add(bb.toBytes());
    return _bodies.length - 1;
  }

  String _descriptorBody() {
    final f = font;
    return '<< /Type /FontDescriptor'
        ' /FontName /${f.name}'
        ' /Flags 32'
        ' /FontBBox [${f.bboxXMin} ${f.bboxYMin} ${f.bboxXMax} ${f.bboxYMax}]'
        ' /ItalicAngle 0'
        ' /Ascent ${f.ascent}'
        ' /Descent ${f.descent}'
        ' /CapHeight ${f.capHeight}'
        ' /StemV 80'
        ' /FontFile2 $fontFile2Obj 0 R >>';
  }

  String _cidFontBody() {
    final f = font;
    final w = StringBuffer('0 [');
    for (var g = 0; g < f.numGlyphs; g++) {
      if (g > 0) w.write(' ');
      final w1000 = (f.advanceOfGlyph(g) * 1000.0 / f.unitsPerEm).round();
      w.write(w1000);
    }
    w.write(']');
    return '<< /Type /Font'
        ' /Subtype /CIDFontType2'
        ' /BaseFont /${f.name}'
        ' /CIDSystemInfo << /Registry (Adobe) /Ordering (Identity) /Supplement 0 >>'
        ' /FontDescriptor $fontDescriptorObj 0 R'
        ' /W [$w]'
        ' /CIDToGIDMap /Identity >>';
  }

  String _type0Body() {
    return '<< /Type /Font'
        ' /Subtype /Type0'
        ' /BaseFont /${font.name}'
        ' /Encoding /Identity-H'
        ' /DescendantFonts [$cidFontObj 0 R]'
        ' /ToUnicode $toUnicodeObj 0 R >>';
  }

  /// ToUnicode CMap: gid → Unicode (bfchar блоками до 100 записей).
  /// Минимальный вид: пролог /CIDInit /ProcSet findresource… не требуется
  /// для встроенного ToUnicode и вызывает «no builtin cmap file» у MuPDF.
  Uint8List _toUnicodeBody() {
    final sb = StringBuffer()
      ..write('begincmap\n')
      ..write('/CIDSystemInfo << /Registry (Adobe) /Ordering (UCS) '
          '/Supplement 0 >> def\n')
      ..write('/CMapName /Adobe-Identity-UCS def\n')
      ..write('/CMapType 2 def\n')
      ..write('1 begincodespacerange\n')
      ..write('<0000> <FFFF>\n')
      ..write('endcodespacerange\n');
    final gids = _gidToCp.keys.toList()..sort();
    for (var i = 0; i < gids.length; i += 100) {
      final end = math.min(i + 100, gids.length);
      sb.write('${end - i} beginbfchar\n');
      for (var k = i; k < end; k++) {
        final g = gids[k];
        final cp = _gidToCp[g]!;
        final gh = g.toRadixString(16).toUpperCase().padLeft(4, '0');
        final ch = cp.toRadixString(16).toUpperCase().padLeft(4, '0');
        sb.write('<$gh> <$ch>\n');
      }
      sb.write('endbfchar\n');
    }
    sb.write('endcmap\n');
    return ascii.encode(sb.toString());
  }

  /// Новая страница (холст рисует в поток контента).
  PdfCanvas newPage() {
    final c = PdfCanvas(this);
    _pages.add(c);
    return c;
  }

  /// Число созданных страниц.
  int get pageCount => _pages.length;

  /// Сборка: объекты каталога/страниц + xref + trailer.
  Uint8List build() {
    // Потоки контента страниц.
    final contentObjs = <int>[];
    for (final p in _pages) {
      contentObjs.add(_addStream(p.bytes));
    }
    // Объект Pages резервируем заранее (на него ссылаются страницы).
    _bodies.add(Uint8List(0));
    final pagesObj = _bodies.length - 1;
    // Страницы.
    final pageObjs = <int>[];
    for (var i = 0; i < _pages.length; i++) {
      final body = '<< /Type /Page'
          ' /Parent $pagesObj 0 R'
          ' /MediaBox [0 0 ${_pdfNum(pageWidth)} ${_pdfNum(pageHeight)}]'
          ' /Resources << /Font << /F1 $type0FontObj 0 R >> >>'
          ' /Contents ${contentObjs[i]} 0 R >>';
      pageObjs.add(_addAscii(body));
    }
    // Заполняем Pages списком детей.
    final kids = pageObjs.map((n) => '$n 0 R').join(' ');
    _bodies[pagesObj] = ascii.encode(
        '<< /Type /Pages /Kids [$kids] /Count ${pageObjs.length} >>');
    final catalogObj = _addAscii('<< /Type /Catalog /Pages $pagesObj 0 R >>');
    return _serialize(catalogObj);
  }

  Uint8List _resolveBody(Object body) {
    if (body is _Late) return body.build();
    if (body is Uint8List) return body;
    if (body is String) return ascii.encode(body);
    throw StateError('Неизвестное тело объекта PDF.');
  }

  Uint8List _serialize(int catalogObj) {
    final out = BytesBuilder();
    out.add(<int>[0x25, 0x50, 0x44, 0x46, 0x2D, 0x31, 0x2E, 0x34, 0x0A]); // %PDF-1.4\n
    out.add(<int>[0x25, 0xE2, 0xE3, 0xCF, 0xD3, 0x0A]); // бинарный комментарий
    final offsets = <int>[];
    for (var n = 1; n < _bodies.length; n++) {
      offsets.add(out.length);
      out.add(ascii.encode('$n 0 obj\n'));
      out.add(_resolveBody(_bodies[n]));
      out.add(ascii.encode('\nendobj\n'));
    }
    final xrefPos = out.length;
    out.add(ascii.encode('xref\n0 ${_bodies.length}\n'));
    out.add(ascii.encode('0000000000 65535 f \n'));
    for (final off in offsets) {
      out.add(ascii.encode('${off.toString().padLeft(10, '0')} 00000 n \n'));
    }
    out.add(ascii.encode('trailer\n<< /Size ${_bodies.length} '
        '/Root $catalogObj 0 R >>\n'));
    out.add(ascii.encode('startxref\n$xrefPos\n%%EOF\n'));
    return out.toBytes();
  }
}

/// Холст страницы: текст и векторные примитивы.
/// Координаты y задаются ОТ ВЕРХНЕГО края страницы (в pt).
class PdfCanvas {
  final PdfDocument doc;
  final BytesBuilder _b = BytesBuilder();

  PdfCanvas(this.doc);

  Uint8List get bytes => _b.toBytes();

  /// Печать строки. [yTop] — базовая линия от верхнего края страницы.
  void text(String s,
      {required double x, required double yTop, double size = 9.0}) {
    if (s.isEmpty) return;
    final py = doc.pageHeight - yTop;
    final hex = StringBuffer();
    for (final cp in s.runes) {
      var gid = doc.font.glyphFor(cp);
      var writtenCp = cp;
      if (gid < 0) {
        // Нет глифа: пробуем «?», затем пробел.
        writtenCp = 0x3F;
        gid = doc.font.glyphFor(writtenCp);
        if (gid < 0) {
          writtenCp = 0x20;
          gid = doc.font.glyphFor(writtenCp);
        }
      }
      if (gid < 0) continue;
      hex.write(gid.toRadixString(16).toUpperCase().padLeft(4, '0'));
      doc._gidToCp.putIfAbsent(gid, () => writtenCp);
    }
    if (hex.isEmpty) return;
    _b.add(ascii.encode('BT /F1 ${_pdfNum(size)} Tf '
        '1 0 0 1 ${_pdfNum(x)} ${_pdfNum(py)} Tm <$hex> Tj ET\n'));
  }

  /// Прямоугольник (обводка). Координаты: верхний левый угол.
  void rect(double x, double yTop, double w, double h,
      {double lineWidth = 0.6}) {
    final py = doc.pageHeight - yTop - h;
    _b.add(ascii.encode('q ${_pdfNum(lineWidth)} w '
        '${_pdfNum(x)} ${_pdfNum(py)} ${_pdfNum(w)} ${_pdfNum(h)} re S Q\n'));
  }

  /// Отрезок (обводка). y — от верхнего края.
  void line(double x1, double y1Top, double x2, double y2Top,
      {double lineWidth = 0.6}) {
    final y1 = doc.pageHeight - y1Top;
    final y2 = doc.pageHeight - y2Top;
    _b.add(ascii.encode('q ${_pdfNum(lineWidth)} w '
        '${_pdfNum(x1)} ${_pdfNum(y1)} m ${_pdfNum(x2)} ${_pdfNum(y2)} l S Q\n'));
  }
}
