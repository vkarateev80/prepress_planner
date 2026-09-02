/// Парсер PDF (порт семантики PyMuPDF get_drawings из cam_material pdf_parser.py).
///
/// Поддерживает: объекты/классический xref, /FlateDecode потоки, страницы с
/// /Contents (одиночные и массивы), наследование /MediaBox через /Parent,
/// операторы q/Q/cm/m/l/c/v/y/re/h/S/s/f/F/B/b/n/W, пропуск текста (BT..ET)
/// и изображений (BI..EI). Координаты pt→мм (25.4/72), Y инвертируется
/// относительно высоты страницы (как в Python-эталоне). Слой — 'PDF_VECTOR'.
library;

import 'dart:io';
import 'dart:math' as math;
import 'dart:convert';
import 'dart:typed_data';

import 'base_parser.dart';
import 'parser_exception.dart';
import 'inflate.dart';
import '../model/cam_path.dart';
import '../model/vec2.dart';

const double _ptToMm = 25.4 / 72.0;

class PdfParser extends BaseParser {
  @override
  List<CamPath> parse(String filePath) {
    final f = File(filePath);
    if (!f.existsSync()) {
      throw ParserException('Файл не найден: $filePath');
    }
    final bytes = f.readAsBytesSync();
    final objs = _scanObjects(bytes);
    if (objs.isEmpty) {
      throw ParserException('Ошибка при чтении PDF: не найдены объекты.');
    }
    final pages = _findPages(objs);
    final allPaths = <CamPath>[];
    for (final page in pages) {
      final content = _pageContent(page, objs);
      if (content == null || content.isEmpty) continue;
      final h = page.mediaBox[3] - page.mediaBox[1];
      final paths = _renderContent(content, page.mediaBox, h, objs);
      allPaths.addAll(paths);
    }
    if (allPaths.isEmpty) {
      throw ParserException('В PDF-файле не найдено ни одного контура.');
    }
    return allPaths;
  }

  // ============================================================
  // Объекты и страницы
  // ============================================================

  static final RegExp _objRe = RegExp(r'(\d+)\s+(\d+)\s+obj', caseSensitive: false);

  Map<int, _PdfObj> _scanObjects(Uint8List bytes) {
    final text = latin1.decode(bytes);
    final objs = <int, _PdfObj>{};
    for (final m in _objRe.allMatches(text)) {
      final num = int.parse(m.group(1)!);
      final endIdx = text.indexOf('endobj', m.end);
      if (endIdx < 0) continue;
      var body = text.substring(m.end, endIdx);
      Uint8List? stream;
      final si = body.indexOf('stream');
      if (si >= 0) {
        final dictPart = body.substring(0, si);
        var after = si + 'stream'.length;
        if (after < body.length && body[after] == '\r') after++;
        if (after < body.length && body[after] == '\n') after++;
        final ei = body.indexOf('endstream', after);
        final streamText = ei > after ? body.substring(after, ei) : body.substring(after);
        stream = _latin1(streamText);
        body = dictPart;
      }
      objs[num] = _PdfObj(num, body, stream);
    }
    return objs;
  }

  Uint8List _latin1(String s) {
    final out = Uint8List(s.length);
    for (var i = 0; i < s.length; i++) {
      out[i] = s.codeUnitAt(i) & 0xFF;
    }
    return out;
  }

  List<_Page> _findPages(Map<int, _PdfObj> objs) {
    final pages = <_Page>[];
    for (final obj in objs.values) {
      final dict = _dictOf(obj.dict);
      if (dict == null) continue;
      if (_nameOf(dict, 'Type') != 'Page') continue;
      final box = _mediaBox(dict, objs);
      final contents = <int>[];
      final c = dict['Contents'];
      if (c is String) {
        final r = _ref(c);
        if (r != null) contents.add(r.$1);
      } else if (c is List) {
        for (final e in c) {
          if (e is String) {
            final r = _ref(e);
            if (r != null) contents.add(r.$1);
          }
        }
      }
      pages.add(_Page(obj.num, box, contents));
    }
    return pages;
  }

  List<double> _mediaBox(Map<String, dynamic> dict, Map<int, _PdfObj> objs) {
    var d = dict;
    var guard = 0;
    while (guard++ < 30) {
      final box = _numArray(d, 'MediaBox');
      if (box != null && box.length >= 4) return box;
      final parent = d['Parent'];
      if (parent is String) {
        final r = _ref(parent);
        final pd = r == null ? null : objs[r.$1]?.dict;
        final next = pd == null ? null : _dictOf(pd);
        if (next != null) {
          d = next;
          continue;
        }
      }
      break;
    }
    return const [0, 0, 595.28, 841.89];
  }

  // ============================================================
  // Словари
  // ============================================================

  Map<String, dynamic>? _dictOf(String body) {
    final s = body.indexOf('<<');
    final e = body.lastIndexOf('>>');
    if (s < 0 || e <= s) return null;
    return _parseDict(_tokenizeDict(body.substring(s + 2, e)));
  }

  List<dynamic> _tokenizeDict(String s) {
    final out = <dynamic>[];
    var i = 0;
    while (i < s.length) {
      final ch = s[i];
      if (ch == ' ' || ch == '\t' || ch == '\r' || ch == '\n' || ch == '\u0000') {
        i++;
        continue;
      }
      if (ch == '/') {
        final m = RegExp(r'^/([^\s/<>\[\]()%]+)').firstMatch(s.substring(i))!;
        out.add('/${m.group(1)}');
        i += m.group(0)!.length;
        continue;
      }
      if (ch == '[') {
        var depth = 1;
        var j = i + 1;
        while (j < s.length && depth > 0) {
          if (s[j] == '[') depth++;
          if (s[j] == ']') depth--;
          j++;
        }
        out.add(_tokenizeDict(s.substring(i + 1, j - 1)));
        i = j;
        continue;
      }
      if (ch == '(') {
        var depth = 1;
        var j = i + 1;
        while (j < s.length && depth > 0) {
          if (s[j] == '\\') {
            j += 2;
            continue;
          }
          if (s[j] == '(') depth++;
          if (s[j] == ')') depth--;
          j++;
        }
        out.add(s.substring(i, j));
        i = j;
        continue;
      }
      if (ch == '<') {
        final j = s.indexOf('>', i);
        if (j > i) out.add(s.substring(i, j + 1));
        i = (j > i ? j + 1 : i + 1);
        continue;
      }
      final m = RegExp(r'^[^\s/<>\[\]()%]+').firstMatch(s.substring(i));
      if (m != null) {
        out.add(m.group(0));
        i += m.group(0)!.length;
      } else {
        i++;
      }
    }
    return out;
  }

  Map<String, dynamic> _parseDict(List<dynamic> tokens) {
    final map = <String, dynamic>{};
    String? key;
    dynamic pending;
    for (final t in tokens) {
      if (t is String && t.startsWith('/')) {
        if (key != null) {
          // Имя после ключа — это ЗНАЧЕНИЕ ключа (/Type /Page).
          map[key] = t;
          key = null;
          pending = null;
        } else {
          key = t.substring(1);
        }
      } else if (key != null) {
        // Сначала косвенная ссылка "N G R" (целые числа).
        if (t is String && RegExp(r'^\d+$').hasMatch(t) && pending is double) {
          final first = pending as double;
          final firstStr = first == first.roundToDouble()
              ? first.toInt().toString()
              : first.toString();
          map[key] = '$firstStr ${int.parse(t)} R';
          key = null;
          pending = null;
        } else {
          final n = double.tryParse(t is String ? t : '');
          if (n != null) {
            pending = n;
          } else {
            map[key] = t;
            key = null;
            pending = null;
          }
        }
      }
    }
    if (key != null) map[key] = pending ?? true;
    return map;
  }

  String? _nameOf(Map<String, dynamic> d, String k) {
    var v = d[k];
    if (v is List && v.length == 1) v = v[0];
    if (v is String && v.startsWith('/')) return v.substring(1);
    return null;
  }

  List<double>? _numArray(Map<String, dynamic> d, String k) {
    final v = d[k];
    if (v is! List) return null;
    final out = <double>[];
    for (final e in v) {
      final n = double.tryParse(e is String ? e : '');
      if (n == null) return null;
      out.add(n);
    }
    return out;
  }

  (int, int)? _ref(String s) {
    final m = RegExp(r'^\s*(\d+)\s+(\d+)\s+R\s*$').firstMatch(s);
    return m == null ? null : (int.parse(m.group(1)!), int.parse(m.group(2)!));
  }

  Uint8List? _streamData(_PdfObj obj) {
    if (obj.stream == null) return null;
    final dict = _dictOf(obj.dict);
    final filter = dict == null ? null : _nameOf(dict, 'Filter');
    if (filter == 'FlateDecode' || filter == 'Fl') {
      final s = obj.stream!;
      // Некоторые производители оборачивают FlateDecode в zlib (заголовок
      // CMF/FLG) вопреки спецe. Если заголовок валиден — распаковываем как
      // zlib ПЕРВЫМ: raw-inflate по zlib-потоку может «успешно» выдать мусор
      // (stored-block из случайных байт заголовка), и fallback не сработает.
      if (_isZlibHeader(s)) {
        try {
          return inflateZlib(s);
        } catch (_) {
          try {
            return inflate(s);
          } catch (_) {
            return null;
          }
        }
      }
      try {
        return inflate(s);
      } catch (_) {
        try {
          return inflateZlib(s);
        } catch (_) {
          return null;
        }
      }
    }
    return obj.stream;
  }

  /// Валиден ли заголовок zlib (CMF/FLG): CM=8 (deflate), контрольная сумма
  /// (CMF*256+FLG) % 31 == 0.
  bool _isZlibHeader(Uint8List d) {
    if (d.length < 2) return false;
    final cmf = d[0];
    final flg = d[1];
    if ((cmf & 0x0F) != 8) return false;
    return (cmf * 256 + flg) % 31 == 0;
  }

  Uint8List? _pageContent(_Page page, Map<int, _PdfObj> objs) {
    final parts = BytesBuilder();
    for (final ref in page.contentRefs) {
      final obj = objs[ref];
      if (obj == null) continue;
      final data = _streamData(obj);
      if (data != null) parts.add(data);
    }
    final b = parts.toBytes();
    return b.isEmpty ? null : b;
  }

  // ============================================================
  // Рендер контента
  // ============================================================

  List<CamPath> _renderContent(Uint8List content, List<double> mediaBox,
      double pageHeight, Map<int, _PdfObj> objs) {
    final tokens = _tokenizeContent(content);
    final ctmStack = <List<double>>[];
    var ctm = const [1.0, 0.0, 0.0, 1.0, 0.0, 0.0];

    Vec2 toMm(Vec2 p) {
      final px = ctm[0] * p.x + ctm[2] * p.y + ctm[4] - mediaBox[0];
      final py = ctm[1] * p.x + ctm[3] * p.y + ctm[5] - mediaBox[1];
      // PyMuPDF уже инвертирует Y (origin сверху); Python-эталон делает
      // вторичный флип page_height − y, что в сумме даёт PDF user-space
      // (Y вверх). Здесь — сразу PDF user-space: без инверсии.
      return Vec2(px * _ptToMm, py * _ptToMm);
    }

    final drawings = <List<dynamic>>[];
    var subpaths = <List<dynamic>>[];
    var cur = <dynamic>[];
    Vec2? curPt;
    Vec2? subStart;
    var pathOpen = false;

    void startSub(Vec2 p) {
      curPt = p;
      subStart = p;
      cur = <dynamic>[];
      subpaths.add(cur);
      pathOpen = true;
    }

    void paint() {
      if (pathOpen) {
        final items = <dynamic>[];
        for (final sp in subpaths) {
          items.addAll(sp);
        }
        if (items.isNotEmpty) drawings.add(items);
      }
      subpaths = <List<dynamic>>[];
      curPt = null;
      subStart = null;
      pathOpen = false;
    }

    var inText = false;
    var inImage = false;
    final stack = <double>[];
    var i = 0;
    while (i < tokens.length) {
      final tok = tokens[i];
      if (tok is double) {
        if (!inText && !inImage) stack.add(tok);
        i++;
        continue;
      }
      if (tok is! String) {
        i++;
        continue;
      }
      final op = tok;
      if (inText) {
        if (op == 'ET') inText = false;
        i++;
        continue;
      }
      if (inImage) {
        if (op == 'EI') inImage = false;
        i++;
        continue;
      }
      double get(int fromEnd) => stack[stack.length - fromEnd];
      switch (op) {
        case 'BT':
          inText = true;
          break;
        case 'BI':
          inImage = true;
          break;
        case 'q':
          ctmStack.add(List.of(ctm));
          break;
        case 'Q':
          if (ctmStack.isNotEmpty) ctm = ctmStack.removeLast();
          break;
        case 'cm':
          if (stack.length >= 6) {
            ctm = _mul(ctm, [
              get(6), get(5), get(4), get(3), get(2), get(1)
            ]);
          }
          stack.clear();
          break;
        case 'm':
          if (stack.length >= 2) startSub(Vec2(get(2), get(1)));
          stack.clear();
          break;
        case 'l':
          if (stack.length >= 2 && curPt != null && pathOpen) {
            final p = Vec2(get(2), get(1));
            cur.add(['l', toMm(curPt!), toMm(p)]);
            curPt = p;
          }
          stack.clear();
          break;
        case 'c':
          if (stack.length >= 6 && curPt != null && pathOpen) {
            final c1 = Vec2(get(6), get(5));
            final c2 = Vec2(get(4), get(3));
            final p = Vec2(get(2), get(1));
            cur.add(['c', toMm(curPt!), toMm(c1), toMm(c2), toMm(p)]);
            curPt = p;
          }
          stack.clear();
          break;
        case 'v':
          if (stack.length >= 4 && curPt != null && pathOpen) {
            // v x2 y2 x3 y3: c1 = current, c2 = (x2,y2), end = (x3,y3)
            final c2 = Vec2(get(4), get(3));
            final p = Vec2(get(2), get(1));
            cur.add(['c', toMm(curPt!), toMm(curPt!), toMm(c2), toMm(p)]);
            curPt = p;
          }
          stack.clear();
          break;
        case 'y':
          if (stack.length >= 4 && curPt != null && pathOpen) {
            // y x1 y1 x3 y3: c1 = (x1,y1), c2 = current, end = (x3,y3)
            final c1 = Vec2(get(4), get(3));
            final p = Vec2(get(2), get(1));
            cur.add(['c', toMm(curPt!), toMm(c1), toMm(curPt!), toMm(p)]);
            curPt = p;
          }
          stack.clear();
          break;
        case 're':
          if (stack.length >= 4) {
            final x = get(4), y = get(3), w = get(2), h = get(1);
            final r0 = toMm(Vec2(x, y));
            final r1 = toMm(Vec2(x + w, y));
            final r2 = toMm(Vec2(x + w, y + h));
            final r3 = toMm(Vec2(x, y + h));
            cur = <dynamic>[['re', r0, r1, r2, r3]];
            subpaths = <List<dynamic>>[cur];
            pathOpen = true;
            curPt = Vec2(x, y);
            subStart = curPt;
          }
          stack.clear();
          break;
        case 'h':
          if (pathOpen && curPt != null && subStart != null &&
              (curPt! - subStart!).length > 1e-9) {
            cur.add(['l', toMm(curPt!), toMm(subStart!)]);
            curPt = subStart;
          }
          stack.clear();
          break;
        case 'S':
        case 's':
        case 'f':
        case 'F':
        case 'f*':
        case 'B':
        case 'B*':
        case 'b':
        case 'b*':
          paint();
          stack.clear();
          break;
        case 'n':
        case 'W':
        case 'W*':
          subpaths = <List<dynamic>>[];
          curPt = null;
          subStart = null;
          pathOpen = false;
          stack.clear();
          break;
        default:
          stack.clear();
      }
      i++;
    }
    return _assemble(drawings);
  }

  List<double> _mul(List<double> m1, List<double> m2) => [
        m1[0] * m2[0] + m1[2] * m2[1],
        m1[1] * m2[0] + m1[3] * m2[1],
        m1[0] * m2[2] + m1[2] * m2[3],
        m1[1] * m2[2] + m1[3] * m2[3],
        m1[0] * m2[4] + m1[2] * m2[5] + m1[4],
        m1[1] * m2[4] + m1[3] * m2[5] + m1[5],
      ];

  List<dynamic> _tokenizeContent(Uint8List content) {
    final s = latin1.decode(content);
    final out = <dynamic>[];
    var i = 0;
    while (i < s.length) {
      final ch = s[i];
      if (ch == ' ' || ch == '\t' || ch == '\r' || ch == '\n' || ch == '\u0000') {
        i++;
        continue;
      }
      if (ch == '%') {
        final j = s.indexOf('\n', i);
        i = j < 0 ? s.length : j + 1;
        continue;
      }
      if (ch == '(') {
        var depth = 1;
        var j = i + 1;
        while (j < s.length && depth > 0) {
          if (s[j] == '\\') {
            j += 2;
            continue;
          }
          if (s[j] == '(') depth++;
          if (s[j] == ')') depth--;
          j++;
        }
        out.add('STR');
        i = j;
        continue;
      }
      if (ch == '<') {
        final j = s.indexOf('>', i);
        out.add('HEX');
        i = j < 0 ? s.length : j + 1;
        continue;
      }
      final numM = RegExp(r'^[-+]?(\d+\.?\d*|\.\d+)([eE][-+]?\d+)?')
          .firstMatch(s.substring(i));
      if (numM != null && RegExp(r'[0-9.\-+]').hasMatch(ch)) {
        out.add(double.parse(numM.group(0)!));
        i += numM.group(0)!.length;
        continue;
      }
      final opM = RegExp(r'^[A-Za-z*]+').firstMatch(s.substring(i));
      if (opM != null) {
        out.add(opM.group(0));
        i += opM.group(0)!.length;
        continue;
      }
      i++;
    }
    return out;
  }

  /// Сборка CamPath из отрисованных items (порт python pdf_parser.py).
  List<CamPath> _assemble(List<List<dynamic>> drawings) {
    final camPaths = <CamPath>[];
    for (final items in drawings) {
      var cur = <Vec2>[];
      for (final item in items) {
        final op = item[0] as String;
        if (op == 'l') {
          final p1 = item[1] as Vec2, p2 = item[2] as Vec2;
          if (cur.isEmpty) {
            cur.add(p1);
          } else if ((p1 - cur.last).length > 1e-4) {
            if (cur.length > 1) camPaths.add(_path(cur));
            cur = [p1];
          }
          cur.add(p2);
        } else if (op == 'c') {
          final p1 = item[1] as Vec2, p2 = item[2] as Vec2;
          final p3 = item[3] as Vec2, p4 = item[4] as Vec2;
          if (cur.isEmpty) {
            cur.add(p1);
          } else if ((p1 - cur.last).length > 1e-4) {
            if (cur.length > 1) camPaths.add(_path(cur));
            cur = [p1];
          }
          final approx = (p2 - p1).length + (p3 - p2).length + (p4 - p3).length;
          final segments = math.max(5, math.min(200, (approx / 0.05).ceil()));
          for (var s = 1; s <= segments; s++) {
            final t = s / segments;
            final u = 1 - t;
            final x = u * u * u * p1.x +
                3 * u * u * t * p2.x +
                3 * u * t * t * p3.x +
                t * t * t * p4.x;
            final y = u * u * u * p1.y +
                3 * u * u * t * p2.y +
                3 * u * t * t * p3.y +
                t * t * t * p4.y;
            cur.add(Vec2(x, y));
          }
        } else if (op == 're') {
          if (cur.length > 1) camPaths.add(_path(cur));
          final p0 = item[1] as Vec2, p1 = item[2] as Vec2;
          final p2 = item[3] as Vec2, p3 = item[4] as Vec2;
          camPaths.add(CamPath([p0, p1, p2, p3, p0],
              isClosed: true, layerName: 'PDF_VECTOR'));
          cur = [];
        }
      }
      if (cur.length > 1) camPaths.add(_path(cur));
    }
    // Фильтр, как в python: len>2 (замкнуть при совпадении концов), len>1.
    final valid = <CamPath>[];
    for (final p in camPaths) {
      if (p.points.length < 2) continue;
      var closed = p.isClosed;
      if (p.points.length > 2 &&
          (p.points.first - p.points.last).length < 1e-4) {
        closed = true;
      }
      valid.add(CamPath(p.points, isClosed: closed, layerName: 'PDF_VECTOR'));
    }
    return valid;
  }

  CamPath _path(List<Vec2> pts) =>
      CamPath(List.of(pts), isClosed: false, layerName: 'PDF_VECTOR');
}

class _PdfObj {
  final int num;
  final String dict;
  final Uint8List? stream;
  _PdfObj(this.num, this.dict, this.stream);
}

class _Page {
  final int objNum;
  final List<double> mediaBox;
  final List<int> contentRefs;
  _Page(this.objNum, this.mediaBox, this.contentRefs);
}
