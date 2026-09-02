/// Парсер DXF (порт семантики ezdxf make_path + flattening из cam_pipeline).
///
/// Сущности: LINE, LWPOLYLINE (с bulge), POLYLINE+VERTEX, CIRCLE, ARC,
/// SPLINE (B-spline, Cox-de Boor), ELLIPSE. Единицы — $INSUNITS
/// (по умолчанию 4 = мм, как в Python-эталоне), результат — мм, Y вверх.
/// Кривые дискретизируются: дуги/окружности — хорда ~0.05 мм, сплайны —
/// равномерная выборка ~0.05 мм по длине (верхняя граница 20000 точек).
library;

import 'dart:io';
import 'dart:math' as math;
import 'dart:convert';

import 'base_parser.dart';
import 'parser_exception.dart';
import '../model/cam_path.dart';
import '../model/vec2.dart';

class DxfParser extends BaseParser {
  @override
  List<CamPath> parse(String filePath) {
    final f = File(filePath);
    if (!f.existsSync()) {
      throw ParserException('Файл не найден: $filePath');
    }
    late List<int> bytes;
    try {
      bytes = f.readAsBytesSync();
    } catch (e) {
      throw ParserException('Ошибка при чтении DXF файла: $e');
    }
    String text;
    try {
      text = utf8.decode(bytes, allowMalformed: true);
    } catch (_) {
      text = latin1.decode(bytes);
    }
    // Строки DXF могут заканчиваться \r\n.
    final lines = text.split(RegExp(r'\r?\n'));

    final pairs = <(int, String)>[];
    var i = 0;
    while (i + 1 < lines.length) {
      final codeStr = lines[i].trim();
      final val = lines[i + 1];
      final code = int.tryParse(codeStr);
      if (code != null) {
        pairs.add((code, val));
      }
      i += 2;
    }

    // Единицы: $INSUNITS в секции HEADER (группа 70 после 9="$INSUNITS").
    var insunits = 4;
    for (var k = 0; k + 1 < pairs.length; k++) {
      if (pairs[k].$1 == 9 && pairs[k].$2.trim() == r'$INSUNITS') {
        for (var m = k + 1; m < pairs.length && m < k + 6; m++) {
          if (pairs[m].$1 == 70) {
            insunits = int.tryParse(pairs[m].$2.trim()) ?? 4;
            break;
          }
        }
        break;
      }
    }
    double scale = 1.0;
    if (insunits == 1) {
      scale = 25.4; // дюймы
    } else if (insunits == 5) {
      scale = 10.0; // см
    } else if (insunits == 6) {
      scale = 1000.0; // м
    }

    final paths = <CamPath>[];
    var k = 0;
    var inEntities = false;
    while (k < pairs.length) {
      final (code, value) = pairs[k];
      if (code == 0) {
        final t = value.trim();
        if (t == 'SECTION') {
          // следующая пара: 2 + имя секции
          if (k + 1 < pairs.length && pairs[k + 1].$1 == 2) {
            inEntities = pairs[k + 1].$2.trim() == 'ENTITIES';
          }
          k += 2;
          continue;
        }
        if (t == 'ENDSEC' || t == 'EOF') {
          inEntities = false;
          k++;
          continue;
        }
        if (inEntities) {
          // Начало сущности.
          final ent = _parseEntity(pairs, k, scale);
          k = ent.$1;
          final path = ent.$2;
          if (path != null) paths.add(path);
          continue;
        }
      }
      k++;
    }
    if (paths.isEmpty) {
      throw ParserException('В DXF-файле не найдено ни одного контура.');
    }
    return paths;
  }

  // ============================================================
  // Разбор сущности: возвращает (индекс после сущности, CamPath?)
  // ============================================================
  (int, CamPath?) _parseEntity(List<(int, String)> pairs, int start, double scale) {
    final type = pairs[start].$2.trim();
    var k = start + 1;
    final attrs = <int, String>{};
    // Собираем атрибуты до следующей группы 0 (не вложенной VERTEX).
    final verts = <(double, double)>[];
    final bulges = <double>[];
    var layer = '';
    while (k < pairs.length) {
      final (code, value) = pairs[k];
      if (code == 0) {
        final t = value.trim();
        if (t == 'VERTEX' && type == 'POLYLINE') {
          // Вложенная вершина: читаем её атрибуты.
          var kk = k + 1;
          double? vx, vy;
          while (kk < pairs.length) {
            final (c2, v2) = pairs[kk];
            if (c2 == 0) break;
            if (c2 == 10) vx = double.tryParse(v2.trim());
            if (c2 == 20) vy = double.tryParse(v2.trim());
            kk++;
          }
          if (vx != null && vy != null) verts.add((vx, vy));
          k = kk;
          continue;
        }
        if (t == 'SEQEND') {
          k++;
          break;
        }
        break; // следующая сущность
      }
      if (code == 8) layer = value.trim();
      if (code == 10 || code == 11) attrs[code] = value.trim();
      if (code == 20 || code == 21) attrs[code] = value.trim();
      if (code == 40) attrs[40] = value.trim();
      if (code == 50) attrs[50] = value.trim();
      if (code == 51) attrs[51] = value.trim();
      if (code == 41) attrs[41] = value.trim();
      if (code == 42) attrs[42] = value.trim();
      if (code == 70) attrs[70] = value.trim();
      if (code == 71) attrs[71] = value.trim();
      if (type == 'LWPOLYLINE') {
        if (code == 10 || code == 20) {
          // координаты вершины LWPOLYLINE идут подряд; обрабатываем в паре
          // накоплением ниже — здесь просто сохраняем последние значения.
        }
      }
      k++;
    }

    double? num(int c) {
      final s = attrs[c];
      return s == null ? null : double.tryParse(s);
    }

    final layerName = _decodeDxfText(layer);
    final sx = scale;

    try {
      if (type == 'LINE') {
        final x1 = num(10), y1 = num(20), x2 = num(11), y2 = num(21);
        if (x1 == null || y1 == null || x2 == null || y2 == null) return (k, null);
        final closed = (Vec2(x1, y1) - Vec2(x2, y2)).length < 1e-6;
        return (k,
            CamPath([Vec2(x1 * sx, y1 * sx), Vec2(x2 * sx, y2 * sx)],
                isClosed: closed, layerName: layerName));
      }

      if (type == 'CIRCLE') {
        final cx = num(10), cy = num(20), r = num(40);
        if (cx == null || cy == null || r == null || r <= 0) return (k, null);
        return (k,
            CamPath(_circlePts(cx, cy, r).map((p) => Vec2(p.x * sx, p.y * sx)).toList(),
                isClosed: true, layerName: layerName));
      }

      if (type == 'ARC') {
        final cx = num(10), cy = num(20), r = num(40);
        final a0 = num(50), a1 = num(51);
        if (cx == null || cy == null || r == null || r <= 0) return (k, null);
        final startDeg = a0 ?? 0.0, endDeg = a1 ?? 360.0;
        return (k,
            CamPath(_arcPts(cx, cy, r, startDeg, endDeg)
                .map((p) => Vec2(p.x * sx, p.y * sx))
                .toList(),
                isClosed: false, layerName: layerName));
      }

      if (type == 'LWPOLYLINE') {
        // Вершины: 10/20 повторяются; bulge 42 — между вершинами.
        // Перечитываем диапазон сущности заново по парам.
        final pts = <(double, double)>[];
        final bul = <double>[];
        var kk = start + 1;
        while (kk < k) {
          final (c2, v2) = pairs[kk];
          if (c2 == 10 || c2 == 20) {
            // Накапливаем пару: обрабатываем в момент прихода 20.
            attrs[c2] = v2.trim();
            if (c2 == 20) {
              final x = double.tryParse(attrs[10] ?? '');
              final y = double.tryParse(v2.trim());
              if (x != null && y != null) pts.add((x, y));
            }
          } else if (c2 == 42) {
            bul.add(double.tryParse(v2.trim()) ?? 0.0);
          }
          kk++;
        }
        if (pts.isEmpty) return (k, null);
        final closedFlag = (int.tryParse(attrs[70] ?? '0') ?? 0) & 1 != 0;
        final out = <Vec2>[];
        for (var v = 0; v < pts.length; v++) {
          out.add(Vec2(pts[v].$1 * sx, pts[v].$2 * sx));
          // bulge между v и v+1
          if (v + 1 < pts.length && v < bul.length && bul[v].abs() > 1e-9) {
            final arc = _bulgePts(pts[v], pts[v + 1], bul[v]);
            for (final p in arc.skip(1)) {
              out.add(Vec2(p.x * sx, p.y * sx));
            }
          } else if (v + 1 == pts.length && closedFlag && v < bul.length &&
              bul[v].abs() > 1e-9) {
            final arc = _bulgePts(pts[v], pts[0], bul[v]);
            for (final p in arc.skip(1)) {
              out.add(Vec2(p.x * sx, p.y * sx));
            }
          }
        }
        return (k,
            CamPath(out, isClosed: closedFlag, layerName: layerName));
      }

      if (type == 'POLYLINE') {
        // Вложенные VERTEX уже собраны в verts.
        if (verts.length < 2) return (k, null);
        final closedFlag = (int.tryParse(attrs[70] ?? '0') ?? 0) & 1 != 0;
        final out = <Vec2>[];
        for (final v in verts) {
          out.add(Vec2(v.$1 * sx, v.$2 * sx));
        }
        var closed = closedFlag;
        if (!closed && (out.first - out.last).length < 1e-6) closed = true;
        return (k, CamPath(out, isClosed: closed, layerName: layerName));
      }

      if (type == 'SPLINE') {
        final knots = <double>[];
        final ctrl = <(double, double)>[];
        var deg = 3;
        var flags = 0;
        var kk = start + 1;
        double? curX;
        while (kk < k) {
          final (c2, v2) = pairs[kk];
          if (c2 == 71) deg = int.tryParse(v2.trim()) ?? 3;
          if (c2 == 70) flags = int.tryParse(v2.trim()) ?? 0;
          if (c2 == 40) knots.add(double.tryParse(v2.trim()) ?? 0.0);
          if (c2 == 10) curX = double.tryParse(v2.trim());
          if (c2 == 20 && curX != null) {
            final y = double.tryParse(v2.trim());
            if (y != null) ctrl.add((curX, y));
            curX = null;
          }
          kk++;
        }
        if (ctrl.length < 2 || knots.isEmpty) return (k, null);
        final d = deg < 1 ? 3 : deg;
        final closed = (flags & 1 != 0) ||
            (ctrl.length > 1 &&
                (ctrl.first.$1 - ctrl.last.$1).abs() < 1e-6 &&
                (ctrl.first.$2 - ctrl.last.$2).abs() < 1e-6);
        final pts = _splinePts(ctrl, knots, d, closed);
        if (pts.isEmpty) return (k, null);
        return (k,
            CamPath(pts.map((p) => Vec2(p.x * sx, p.y * sx)).toList(),
                isClosed: closed, layerName: layerName));
      }

      if (type == 'ELLIPSE') {
        final cx = num(10), cy = num(20);
        final mx = num(11), my = num(21);
        final ratio = num(40) ?? 1.0;
        final p0 = num(41) ?? 0.0, p1 = num(42) ?? 2 * math.pi;
        if (cx == null || cy == null || mx == null || my == null) return (k, null);
        final a = Vec2(mx, my);
        final b = Vec2(-my, mx) * ratio;
        final n = math.max(24, ((2 * math.pi * math.max(a.length, b.length)) / 0.05).ceil());
        final steps = math.min(20000, n);
        final out = <Vec2>[];
        for (var s = 0; s <= steps; s++) {
          final t = p0 + (p1 - p0) * s / steps;
          final p = Vec2(cx, cy) + a * math.cos(t) + b * math.sin(t);
          out.add(Vec2(p.x * sx, p.y * sx));
        }
        final isFull = (p1 - p0).abs() >= 2 * math.pi - 1e-6;
        return (k, CamPath(out, isClosed: isFull, layerName: layerName));
      }
    } catch (_) {
      return (k, null);
    }
    return (k, null);
  }

  // ============================================================
  // Дискретизация кривых
  // ============================================================

  List<Vec2> _circlePts(double cx, double cy, double r) {
    final n = math.max(16, (2 * math.pi * r / 0.05).ceil());
    final out = <Vec2>[];
    for (var s = 0; s < n; s++) {
      final a = 2 * math.pi * s / n;
      out.add(Vec2(cx + r * math.cos(a), cy + r * math.sin(a)));
    }
    return out;
  }

  List<Vec2> _arcPts(double cx, double cy, double r, double startDeg, double endDeg) {
    var a0 = startDeg * math.pi / 180;
    var a1 = endDeg * math.pi / 180;
    var sweep = a1 - a0;
    // DXF: дуга против часовой от start к end.
    while (sweep <= 0) sweep += 2 * math.pi;
    final len = r * sweep;
    final n = math.max(8, (len / 0.05).ceil());
    final out = <Vec2>[];
    for (var s = 0; s <= n; s++) {
      final a = a0 + sweep * s / n;
      out.add(Vec2(cx + r * math.cos(a), cy + r * math.sin(a)));
    }
    return out;
  }

  /// Дуга по bulge (LWPOLYLINE): bulge = tan(θ/4), θ — центральный угол.
  List<Vec2> _bulgePts((double, double) p0, (double, double) p1, double bulge) {
    final a = Vec2(p0.$1, p0.$2);
    final b = Vec2(p1.$1, p1.$2);
    final chord = (b - a).length;
    if (chord < 1e-9) return [a, b];
    final theta = 4 * math.atan(bulge);
    final r = chord / (2 * math.sin(theta.abs() / 2).clamp(1e-9, 1.0));
    // Центр: перпендикуляр к середине хорды, смещение h = r·cos(θ/2).
    final mid = (a + b) * 0.5;
    final dir = (b - a).normalized;
    final perp = Vec2(-dir.y, dir.x);
    final h = r * math.cos(theta.abs() / 2);
    final center = theta.abs() < math.pi
        ? mid + perp * (bulge > 0 ? h : -h)
        : mid + perp * (bulge > 0 ? -h : h);
    final angA = math.atan2(a.y - center.y, a.x - center.x);
    final angB = math.atan2(b.y - center.y, b.x - center.x);
    var sweep = angB - angA;
    if (bulge > 0) {
      while (sweep < 0) sweep += 2 * math.pi;
    } else {
      while (sweep > 0) sweep -= 2 * math.pi;
    }
    final rr = (a - center).length;
    final n = math.max(4, (rr * sweep.abs() / 0.05).ceil());
    final out = <Vec2>[];
    for (var s = 0; s <= n; s++) {
      final ang = angA + sweep * s / n;
      out.add(Vec2(center.x + rr * math.cos(ang), center.y + rr * math.sin(ang)));
    }
    return out;
  }

  /// B-spline (Cox-de Boor). Если [closed] — контрольные точки замыкаются.
  List<Vec2> _splinePts(List<(double, double)> ctrl, List<double> knots, int d, bool closed) {
    // Периодические сплайны в DXF имеют флаг 2 и «лишние» узлы/точки;
    // здесь работаем с клампированными узлами (наш корпус — clamped).
    final xs = ctrl.map((c) => c.$1).toList();
    final ys = ctrl.map((c) => c.$2).toList();
    final ks = knots;

    double basis(int i, int deg, double u) {
      if (deg == 0) {
        return (u >= ks[i] && u < ks[i + 1]) ? 1.0 : 0.0;
      }
      final d1 = ks[i + deg] - ks[i];
      final d2 = ks[i + deg + 1] - ks[i + 1];
      var w1 = 0.0, w2 = 0.0;
      if (d1.abs() > 1e-12) w1 = (u - ks[i]) / d1;
      if (d2.abs() > 1e-12) w2 = (ks[i + deg + 1] - u) / d2;
      return w1 * basis(i, deg - 1, u) + w2 * basis(i + 1, deg - 1, u);
    }

    final n = xs.length;
    final dd = d.clamp(1, 5);
    final u0 = ks[dd];
    final u1 = ks[n];
    // Оценка длины по контрольному полигону для выбора числа выборок.
    var ctrlLen = 0.0;
    for (var i = 1; i < n; i++) {
      ctrlLen += math.sqrt(math.pow(xs[i] - xs[i - 1], 2) + math.pow(ys[i] - ys[i - 1], 2));
    }
    final steps = math.min(20000, math.max(64, (ctrlLen / 0.05).ceil()));
    final out = <Vec2>[];
    for (var s = 0; s <= steps; s++) {
      final u = u0 + (u1 - u0) * s / steps;
      var x = 0.0, y = 0.0, wsum = 0.0;
      for (var i = 0; i < n; i++) {
        final b = basis(i, dd, u);
        if (b.abs() > 1e-14) {
          x += xs[i] * b;
          y += ys[i] * b;
          wsum += b;
        }
      }
      if (wsum.abs() < 1e-12) continue;
      out.add(Vec2(x / wsum, y / wsum));
    }
    // Дубликаты подряд (клампированные концы) — убрать.
    final clean = <Vec2>[];
    for (final p in out) {
      if (clean.isEmpty || (clean.last - p).length > 1e-7) clean.add(p);
    }
    return clean;
  }

  /// Декодирование \U+XXXX в именах DXF (не-ASCII имена слоёв).
  String _decodeDxfText(String s) {
    if (!s.contains(r'\U+')) return s;
    final sb = StringBuffer();
    var i = 0;
    while (i < s.length) {
      if (i + 5 < s.length && s.startsWith(r'\U+', i)) {
        final hex = s.substring(i + 3, i + 7);
        final code = int.tryParse(hex, radix: 16);
        if (code != null) {
          sb.writeCharCode(code);
          i += 7;
          continue;
        }
      }
      sb.write(s[i]);
      i++;
    }
    return sb.toString();
  }
}
