/// Парсер SVG (порт семантики svgelements из cam_material svg_parser.py).
///
/// Масштаб: по умолчанию 25.4/96 мм/ед; если заданы физическая ширина и
/// viewBox — width_mm / viewBox_width. Координаты Y инвертируются (SVG Y↓ →
/// мм Y↑). Кривые Безье/дуги дискретизируются по контрольной длине.
/// Слой всех контуров — 'SVG_VECTOR' (как в Python-эталоне).
library;

import 'dart:io';
import 'dart:math' as math;
import 'dart:convert';

import 'base_parser.dart';
import 'parser_exception.dart';
import '../model/cam_path.dart';
import '../model/vec2.dart';

const double _pxToMm = 25.4 / 96.0;

class SvgParser extends BaseParser {
  @override
  List<CamPath> parse(String filePath) {
    final f = File(filePath);
    if (!f.existsSync()) {
      throw ParserException('Файл не найден: $filePath');
    }
    late String text;
    try {
      text = f.readAsStringSync();
    } catch (e) {
      throw ParserException('Ошибка при чтении SVG: $e');
    }

    final root = _parseXml(text);
    if (root == null) {
      throw ParserException('Ошибка при чтении SVG: не удалось разобрать XML.');
    }
    final scale = _svgScale(root);

    final paths = <CamPath>[];
    final visited = <String>{}; // id узлов, чтобы не ходить по кругу
    _walkShapes(root, const _Transform.identity(), scale, paths, visited);
    if (paths.isEmpty) {
      throw ParserException('В SVG-файле не найдено ни одного контура.');
    }
    return paths;
  }

  double _svgScale(_XmlNode svg) {
    final vb = svg.attr('viewBox');
    final width = svg.attr('width');
    if (width != null && vb != null) {
      final vbParts = vb.trim().split(RegExp(r'[\s,]+'));
      if (vbParts.length >= 3) {
        final vbW = double.tryParse(vbParts[2]);
        final wPx = _physicalToPx(width);
        if (vbW != null && vbW > 0 && wPx != null && wPx > 0) {
          return wPx * _pxToMm / vbW;
        }
      }
    }
    return _pxToMm;
  }

  double? _physicalToPx(String v) {
    final m = RegExp(r'^\s*([-+]?[0-9]*\.?[0-9]+)\s*(px|mm|cm|in|pt|pc)?\s*$')
        .firstMatch(v);
    if (m == null) return null;
    final val = double.tryParse(m.group(1)!);
    if (val == null) return null;
    final unit = m.group(2);
    switch (unit) {
      case 'mm':
        return val * 96 / 25.4;
      case 'cm':
        return val * 96 / 2.54;
      case 'in':
        return val * 96;
      case 'pt':
        return val * 96 / 72;
      case 'pc':
        return val * 16;
      default:
        return val; // px или безразмерное
    }
  }

  void _walkShapes(_XmlNode node, _Transform parentTf, double scale,
      List<CamPath> paths, Set<String> visited) {
    if (node.id != null) {
      if (!visited.add(node.id!)) return;
    }
    final tf = parentTf.multiply(_Transform.parse(node.attr('transform')));
    if (node.name == 'path' || node.name == 'rect' || node.name == 'circle' ||
        node.name == 'ellipse' || node.name == 'line' ||
        node.name == 'polyline' || node.name == 'polygon') {
      final pts = _shapePoints(node, tf);
      if (pts != null && pts.length > 1) {
        // Масштаб и инверсия Y (SVG Y вниз → домен Y вверх).
        final mm = pts.map((p) => Vec2(p.x * scale, -p.y * scale)).toList();
        final clean = <Vec2>[];
        for (final p in mm) {
          if (clean.isEmpty || (clean.last - p).length > 1e-4) clean.add(p);
        }
        var closed = false;
        if (clean.length > 2 &&
            (clean.first - clean.last).length < 1e-4) {
          closed = true;
        }
        if (clean.length > 1) {
          paths.add(CamPath(clean, isClosed: closed, layerName: 'SVG_VECTOR'));
        }
      }
    }
    for (final child in node.children) {
      if (child.name == 'defs') continue;
      _walkShapes(child, tf, scale, paths, visited);
    }
  }

  List<Vec2>? _shapePoints(_XmlNode el, _Transform tf) {
    final name = el.name;
    if (name == 'path') {
      final d = el.attr('d');
      if (d == null) return null;
      return _pathPoints(d, tf);
    }
    if (name == 'rect') {
      final x = double.tryParse(el.attr('x') ?? '0') ?? 0;
      final y = double.tryParse(el.attr('y') ?? '0') ?? 0;
      final w = double.tryParse(el.attr('width') ?? '0') ?? 0;
      final h = double.tryParse(el.attr('height') ?? '0') ?? 0;
      final rx = double.tryParse(el.attr('rx') ?? '') ?? 0;
      final ry = double.tryParse(el.attr('ry') ?? '') ?? rx;
      if (w <= 0 || h <= 0) return null;
      if (rx <= 0 && ry <= 0) {
        return _transformPts([
          Vec2(x, y),
          Vec2(x + w, y),
          Vec2(x + w, y + h),
          Vec2(x, y + h),
          Vec2(x, y),
        ], tf);
      }
      final r = math.min(rx, w / 2) < math.min(ry, h / 2)
          ? math.min(rx, w / 2)
          : math.min(ry, h / 2);
      return _transformPts(_roundedRect(x, y, w, h, r), tf);
    }
    if (name == 'circle') {
      final cx = double.tryParse(el.attr('cx') ?? '0') ?? 0;
      final cy = double.tryParse(el.attr('cy') ?? '0') ?? 0;
      final r = double.tryParse(el.attr('r') ?? '0') ?? 0;
      if (r <= 0) return null;
      return _transformPts(_ellipsePts(Vec2(cx, cy), Vec2(r, 0), Vec2(0, r), 0, 2 * math.pi), tf);
    }
    if (name == 'ellipse') {
      final cx = double.tryParse(el.attr('cx') ?? '0') ?? 0;
      final cy = double.tryParse(el.attr('cy') ?? '0') ?? 0;
      final rx = double.tryParse(el.attr('rx') ?? '0') ?? 0;
      final ry = double.tryParse(el.attr('ry') ?? '0') ?? 0;
      if (rx <= 0 || ry <= 0) return null;
      return _transformPts(
          _ellipsePts(Vec2(cx, cy), Vec2(rx, 0), Vec2(0, ry), 0, 2 * math.pi), tf);
    }
    if (name == 'line') {
      final x1 = double.tryParse(el.attr('x1') ?? '') ?? 0;
      final y1 = double.tryParse(el.attr('y1') ?? '') ?? 0;
      final x2 = double.tryParse(el.attr('x2') ?? '') ?? 0;
      final y2 = double.tryParse(el.attr('y2') ?? '') ?? 0;
      return _transformPts([Vec2(x1, y1), Vec2(x2, y2)], tf);
    }
    if (name == 'polyline' || name == 'polygon') {
      final ptsAttr = el.attr('points');
      if (ptsAttr == null) return null;
      final nums = ptsAttr
          .trim()
          .split(RegExp(r'[\s,]+'))
          .map(double.tryParse)
          .whereType<double>()
          .toList();
      final out = <Vec2>[];
      for (var i = 0; i + 1 < nums.length; i += 2) {
        out.add(Vec2(nums[i], nums[i + 1]));
      }
      if (name == 'polygon' && out.isNotEmpty) out.add(out.first);
      return _transformPts(out, tf);
    }
    return null;
  }

  List<Vec2> _transformPts(List<Vec2> pts, _Transform tf) {
    if (tf.isIdentity) return pts;
    return pts.map(tf.apply).toList();
  }

  List<Vec2> _roundedRect(double x, double y, double w, double h, double r) {
    const k = 0.5522847498; // магическая константа Безье для четверти круга
    final out = <Vec2>[];
    void seg(Vec2 a, Vec2 c1, Vec2 c2, Vec2 b) {
      final approx = (c1 - a).length + (c2 - c1).length + (b - c2).length;
      final n = math.max(2, math.min(24, (approx / 0.3).ceil()));
      for (var i = 1; i <= n; i++) {
        final t = i / n;
        out.add(_cubic(a, c1, c2, b, t));
      }
    }

    out.add(Vec2(x + r, y));
    seg(Vec2(x + r, y), Vec2(x + w - r * (1 - k), y), Vec2(x + w, y + r * (1 - k)), Vec2(x + w, y + r));
    out.add(Vec2(x + w, y + h - r));
    seg(Vec2(x + w, y + h - r), Vec2(x + w, y + h - r * (1 - k)), Vec2(x + w - r * (1 - k), y + h), Vec2(x + w - r, y + h));
    out.add(Vec2(x + r, y + h));
    seg(Vec2(x + r, y + h), Vec2(x + r * (1 - k), y + h), Vec2(x, y + h - r * (1 - k)), Vec2(x, y + h - r));
    out.add(Vec2(x, y + r));
    seg(Vec2(x, y + r), Vec2(x, y + r * (1 - k)), Vec2(x + r * (1 - k), y), Vec2(x + r, y));
    out.add(out.first);
    return out;
  }

  List<Vec2> _ellipsePts(Vec2 c, Vec2 a, Vec2 b, double t0, double t1) {
    final approx = 2 * math.pi * math.max(a.length, b.length);
    final n = math.max(8, math.min(400, (approx / 0.5).ceil()));
    final out = <Vec2>[];
    for (var i = 0; i <= n; i++) {
      final t = t0 + (t1 - t0) * i / n;
      out.add(c + a * math.cos(t) + b * math.sin(t));
    }
    out.add(out.first);
    return out;
  }

  Vec2 _cubic(Vec2 a, Vec2 c1, Vec2 c2, Vec2 b, double t) {
    final u = 1 - t;
    return a * (u * u * u) + c1 * (3 * u * u * t) + c2 * (3 * u * t * t) + b * (t * t * t);
  }

  Vec2 _quad(Vec2 a, Vec2 c, Vec2 b, double t) {
    final u = 1 - t;
    return a * (u * u) + c * (2 * u * t) + b * (t * t);
  }

  // ============================================================
  // Path (d)
  // ============================================================

  List<Vec2> _pathPoints(String d, _Transform tf) {
    final cmds = _tokenizePath(d);
    final out = <Vec2>[];
    var cur = const Vec2(0, 0);
    var subStart = const Vec2(0, 0);
    var started = false;
    Vec2? lastControl;
    var lastCmd = '';

    void lineTo(Vec2 p) {
      out.add(p);
      cur = p;
    }

    for (final (cmd, args) in cmds) {
      final abs = cmd == cmd.toUpperCase();
      final c = cmd.toUpperCase();
      var i = 0;
      if (c == 'Z') {
        if ((cur - subStart).length > 1e-9) {
          out.add(subStart);
          cur = subStart;
        }
        lastControl = null;
        lastCmd = 'Z';
        continue;
      }
      while (i < args.length) {
        if (c == 'M') {
          var p = abs ? Vec2(args[i], args[i + 1]) : cur + Vec2(args[i], args[i + 1]);
          i += 2;
          started = true;
          out.add(p);
          cur = p;
          subStart = p;
          // Дополнительные пары после M — линии с тем же признаком rel/abs.
          while (i + 1 < args.length) {
            p = abs ? Vec2(args[i], args[i + 1]) : cur + Vec2(args[i], args[i + 1]);
            i += 2;
            out.add(p);
            cur = p;
          }
        } else if (c == 'L') {
          final x = args[i], y = args[i + 1];
          i += 2;
          lineTo(abs ? Vec2(x, y) : cur + Vec2(x, y));
        } else if (c == 'H') {
          final x = args[i++];
          lineTo(abs ? Vec2(x, cur.y) : Vec2(cur.x + x, cur.y));
        } else if (c == 'V') {
          final y = args[i++];
          lineTo(abs ? Vec2(cur.x, y) : Vec2(cur.x, cur.y + y));
        } else if (c == 'C') {
          final c1 = abs ? Vec2(args[i], args[i + 1]) : cur + Vec2(args[i], args[i + 1]);
          final c2 = abs
              ? Vec2(args[i + 2], args[i + 3])
              : cur + Vec2(args[i + 2], args[i + 3]);
          final p = abs ? Vec2(args[i + 4], args[i + 5]) : cur + Vec2(args[i + 4], args[i + 5]);
          i += 6;
          _sampleCubic(out, cur, c1, c2, p);
          lastControl = c2;
          cur = p;
        } else if (c == 'S') {
          final c1 = (lastCmd == 'C' || lastCmd == 'S') && lastControl != null
              ? cur * 2 - lastControl!
              : cur;
          final c2 = abs
              ? Vec2(args[i], args[i + 1])
              : cur + Vec2(args[i], args[i + 1]);
          final p = abs ? Vec2(args[i + 2], args[i + 3]) : cur + Vec2(args[i + 2], args[i + 3]);
          i += 4;
          _sampleCubic(out, cur, c1, c2, p);
          lastControl = c2;
          cur = p;
        } else if (c == 'Q') {
          final ctrl = abs ? Vec2(args[i], args[i + 1]) : cur + Vec2(args[i], args[i + 1]);
          final p = abs ? Vec2(args[i + 2], args[i + 3]) : cur + Vec2(args[i + 2], args[i + 3]);
          i += 4;
          _sampleQuad(out, cur, ctrl, p);
          lastControl = ctrl;
          cur = p;
        } else if (c == 'T') {
          final ctrl = (lastCmd == 'Q' || lastCmd == 'T') && lastControl != null
              ? cur * 2 - lastControl!
              : cur;
          final p = abs ? Vec2(args[i], args[i + 1]) : cur + Vec2(args[i], args[i + 1]);
          i += 2;
          _sampleQuad(out, cur, ctrl, p);
          lastControl = ctrl;
          cur = p;
        } else if (c == 'A') {
          final rx = args[i].abs(), ry = args[i + 1].abs();
          final rot = args[i + 2];
          final large = args[i + 3] > 0;
          final sweepFlag = args[i + 4] > 0;
          final x = args[i + 5], y = args[i + 6];
          i += 7;
          final p = abs ? Vec2(x, y) : cur + Vec2(x, y);
          final arcPts = _arcTo(cur, p, rx, ry, rot, large, sweepFlag);
          if (arcPts.length > 1) out.addAll(arcPts.sublist(1));
          lastControl = null;
          cur = p;
        } else {
          i = args.length; // неизвестная команда
        }
        lastCmd = c;
      }
    }
    return tf.isIdentity ? out : out.map(tf.apply).toList();
  }

  void _sampleCubic(List<Vec2> out, Vec2 a, Vec2 c1, Vec2 c2, Vec2 b) {
    final approx = (c1 - a).length + (c2 - c1).length + (b - c2).length;
    final step = 0.05;
    final n = math.max(2, math.min(200, (approx / step).ceil()));
    for (var i = 1; i <= n; i++) {
      out.add(_cubic(a, c1, c2, b, i / n));
    }
  }

  void _sampleQuad(List<Vec2> out, Vec2 a, Vec2 c, Vec2 b) {
    final approx = (c - a).length + (b - c).length;
    final step = 0.05;
    final n = math.max(2, math.min(200, (approx / step).ceil()));
    for (var i = 1; i <= n; i++) {
      out.add(_quad(a, c, b, i / n));
    }
  }

  /// SVG arc (endpoint parametrization) → полилиния.
  List<Vec2> _arcTo(Vec2 p0, Vec2 p1, double rx, double ry, double phiDeg,
      bool largeArc, bool sweepFlag) {
    if (rx <= 0 || ry <= 0 || (p0 - p1).length < 1e-9) {
      return [p0, p1];
    }
    final phi = phiDeg * math.pi / 180;
    final cp = math.cos(phi), sp = math.sin(phi);
    final dx = (p0.x - p1.x) / 2, dy = (p0.y - p1.y) / 2;
    final x1p = cp * dx + sp * dy;
    final y1p = -sp * dx + cp * dy;
    // Коррекция радиуса.
    var rx2 = rx * rx, ry2 = ry * ry;
    final x1p2 = x1p * x1p, y1p2 = y1p * y1p;
    final lambda = x1p2 / rx2 + y1p2 / ry2;
    if (lambda > 1) {
      final s = math.sqrt(lambda);
      rx *= s;
      ry *= s;
      rx2 = rx * rx;
      ry2 = ry * ry;
    }
    final num = rx2 * ry2 - rx2 * y1p2 - ry2 * x1p2;
    final den = rx2 * y1p2 + ry2 * x1p2;
    var coef = den.abs() < 1e-12 ? 0.0 : math.sqrt(math.max(0, num / den));
    if (largeArc == sweepFlag) coef = -coef;
    final cxp = coef * (rx * y1p / ry);
    final cyp = coef * (-ry * x1p / rx);
    final cx = cp * cxp - sp * cyp + (p0.x + p1.x) / 2;
    final cy = sp * cxp + cp * cyp + (p0.y + p1.y) / 2;
    double ang(Vec2 v) => math.atan2(v.y, v.x);

    Vec2 toP(double ux, double uy) {
      final x = cp * ux - sp * uy;
      final y = sp * ux + cp * uy;
      return Vec2(x + cx, y + cy);
    }

    final ux1 = (x1p - cxp) / rx, uy1 = (y1p - cyp) / ry;
    final ux2 = (-x1p - cxp) / rx, uy2 = (-y1p - cyp) / ry;
    var theta1 = ang(Vec2(ux1, uy1));
    var dTheta = ang(Vec2(ux2, uy2)) - theta1;
    while (dTheta < 0) dTheta += 2 * math.pi;
    while (dTheta > 2 * math.pi) dTheta -= 2 * math.pi;
    if (!sweepFlag) dTheta -= 2 * math.pi;
    final len = dTheta.abs() * math.max(rx, ry);
    final n = math.max(2, math.min(200, (len / 0.05).ceil()));
    final out = <Vec2>[];
    for (var i = 1; i <= n; i++) {
      final t = theta1 + dTheta * i / n;
      out.add(toP(rx * math.cos(t), ry * math.sin(t)));
    }
    return out;
  }

  List<(String, List<double>)> _tokenizePath(String d) {
    final out = <(String, List<double>)>[];
    final re = RegExp(r'([MmLlHhVvCcSsQqTtAaZz])|([-+]?[0-9]*\.?[0-9]+(?:[eE][-+]?[0-9]+)?)');
    String? cmd;
    final args = <double>[];
    void flush() {
      if (cmd != null) {
        out.add((cmd!, List.of(args)));
        args.clear();
      }
    }

    for (final m in re.allMatches(d)) {
      if (m.group(1) != null) {
        flush();
        cmd = m.group(1);
      } else {
        final v = double.tryParse(m.group(2)!);
        if (v != null) args.add(v);
      }
    }
    flush();
    return out;
  }

  // ============================================================
  // Минимальный XML-токенизатор
  // ============================================================

  _XmlNode? _parseXml(String text) {
    final nodes = <_XmlNode>[];
    _XmlNode? root;
    final stack = <_XmlNode>[];
    final tagRe = RegExp(r'<(\/?)([a-zA-Z0-9:_\-]+)([^>]*?)(\/?)>');
    var pos = 0;
    for (final m in tagRe.allMatches(text)) {
      final isClose = m.group(1) == '/';
      final name = m.group(2)!;
      final rest = m.group(3) ?? '';
      final selfClose = m.group(4) == '/';
      if (isClose) {
        if (stack.isNotEmpty) stack.removeLast();
        continue;
      }
      final node = _XmlNode(name, _parseAttrs(rest));
      if (stack.isNotEmpty) {
        stack.last.children.add(node);
      } else if (root == null) {
        root = node;
      }
      if (!selfClose) stack.add(node);
    }
    return root;
  }

  Map<String, String> _parseAttrs(String s) {
    final attrs = <String, String>{};
    final re = RegExp(r'([a-zA-Z_:][a-zA-Z0-9_:.\-]*)\s*=\s*"([^"]*)"');
    for (final m in re.allMatches(s)) {
      attrs[m.group(1)!] = _decodeEntities(m.group(2)!);
    }
    return attrs;
  }

  String _decodeEntities(String s) => s
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&apos;', "'");
}

class _XmlNode {
  final String name;
  final Map<String, String> attrs;
  final List<_XmlNode> children = [];
  _XmlNode(this.name, this.attrs);

  String? attr(String n) => attrs[n];
  String? get id => attrs['id'];
}

class _Transform {
  static const double _e = 1e-12;
  final double a, b, c, d, e, f;
  const _Transform(this.a, this.b, this.c, this.d, this.e, this.f);

  const _Transform.identity() : this(1, 0, 0, 1, 0, 0);

  bool get isIdentity =>
      (a - 1).abs() < _e && b.abs() < _e && c.abs() < _e &&
      (d - 1).abs() < _e && e.abs() < _e && f.abs() < _e;

  Vec2 apply(Vec2 p) => Vec2(a * p.x + c * p.y + e, b * p.x + d * p.y + f);

  _Transform multiply(_Transform o) => _Transform(
        a * o.a + c * o.b,
        b * o.a + d * o.b,
        a * o.c + c * o.d,
        b * o.c + d * o.d,
        a * o.e + c * o.f + e,
        b * o.e + d * o.f + f,
      );

  static _Transform parse(String? s) {
    var tf = const _Transform.identity();
    if (s == null || s.trim().isEmpty) return tf;
    final re = RegExp(r'([a-zA-Z]+)\s*\(([^)]*)\)');
    for (final m in re.allMatches(s)) {
      final fn = m.group(1)!;
      final nums = m
          .group(2)!
          .split(RegExp(r'[\s,]+'))
          .map(double.tryParse)
          .whereType<double>()
          .toList();
      tf = tf.multiply(_make(fn, nums));
    }
    return tf;
  }

  static _Transform _make(String fn, List<double> v) {
    switch (fn) {
      case 'matrix':
        if (v.length >= 6) return _Transform(v[0], v[1], v[2], v[3], v[4], v[5]);
        return const _Transform.identity();
      case 'translate':
        if (v.isEmpty) return const _Transform.identity();
        return _Transform(1, 0, 0, 1, v[0], v.length > 1 ? v[1] : 0);
      case 'scale':
        if (v.isEmpty) return const _Transform.identity();
        final sy = v.length > 1 ? v[1] : v[0];
        return _Transform(v[0], 0, 0, sy, 0, 0);
      case 'rotate':
        if (v.isEmpty) return const _Transform.identity();
        final ang = v[0] * math.pi / 180;
        final cos = math.cos(ang), sin = math.sin(ang);
        if (v.length >= 3) {
          final cx = v[1], cy = v[2];
          return _Transform(cos, sin, -sin, cos, cx, cy)
              .multiply(_Transform(1, 0, 0, 1, -cx, -cy));
        }
        return _Transform(cos, sin, -sin, cos, 0, 0);
      case 'skewX':
        return _Transform(1, 0, math.tan(v.isEmpty ? 0 : v[0] * math.pi / 180), 1, 0, 0);
      case 'skewY':
        return _Transform(1, math.tan(v.isEmpty ? 0 : v[0] * math.pi / 180), 0, 1, 0, 0);
      default:
        return const _Transform.identity();
    }
  }
}
