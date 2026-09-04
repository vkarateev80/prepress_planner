/// Морфологическое лечение векторной геометрии (порт cam_material
/// src/healer/morphology.py, 1:1): жёсткий предфильтр пыли → снаппинг концов
/// → сшивка цепочек → полигонизация → сварка (buffer ±0.005, round) →
/// извлечение полигонов/отверстий → остаточные «хвосты».
///
/// Слои результата: HEALED_POLY (замкнутые внешние контуры), HEALED_HOLE
/// (замкнутые отверстия), HEALED_TAIL (открытые остатки длиной ≥ minLoopArea).
library;

import '../geom/polygon2.dart';
import '../geom/geom_ops.dart';
import '../geom/geom_boolean.dart';
import '../model/cam_path.dart';
import '../model/vec2.dart';
import 'dart:math' as math;

class MorphologicalHealer {
  final double tolerance;
  final double minLoopArea;

  const MorphologicalHealer(
      {this.tolerance = 0.01, this.minLoopArea = 0.0});

  List<CamPath> heal(List<CamPath> paths) {
    final validLines = <List<Vec2>>[];

    // === 1. ЖЁСТКИЙ ПРЕДФИЛЬТР МУСОРА ===
    for (final p in paths) {
      if (p.points.length < 2) continue;
      final pts = List<Vec2>.of(p.points);
      if (minLoopArea > 0) {
        final closed = p.isClosed || _dist(pts.first, pts.last) < 1e-9;
        if (closed) {
          final ring = cleanRing(pts);
          if (ring.length < 3) continue; // не собирается в полигон — мусор
          if (ringAreaAbs(ring) < minLoopArea) continue; // мелкий замкнутый мусор
        } else {
          if (_polylineLength(pts) < minLoopArea) continue; // короткие штрихи
        }
      }
      validLines.add(pts);
    }

    if (validLines.isEmpty) return const [];

    // === 2. СНАППИНГ ===
    final snapped = _snapEndpoints(validLines);

    // === 3. НОДИНГ + ПОЛИГОНИЗАЦИЯ ===
    // ВАЖНО: полигонизация идёт по снапнутым линиям НАПРЯМУЮ (как
    // unary_union+polygonize у Shapely): lineMerge здесь НЕ применяется —
    // он срезает замыкающий дубль первой точки, и замкнутые после снапа
    // контуры снова «открываются», теряя грань. Сшивка цепочек для
    // полигонизации не нужна (polygonize работает по сегментам).
    final polygons = polygonize(snapped);
    final goodPolygons = <Polygon2>[];
    for (final poly in polygons) {
      if (poly.area >= minLoopArea) goodPolygons.add(poly);
    }

    final healed = <CamPath>[];
    final weldSize = 0.005;

    if (goodPolygons.isNotEmpty) {
      // Сварка: buffer(+weld).buffer(−weld) с round-join, как в Python
      // (join_style=1). Каждый полигон варится отдельно: совместный
      // unary_union почти-касающихся граней (самопересечения исходной
      // кривой) теряет площадь на почти-совпадающих рёбрах.
      final welded = <Polygon2>[];
      for (final poly in goodPolygons) {
        var p = bufferPolygons([poly], weldSize, join: 'round');
        p = bufferPolygons(p, -weldSize, join: 'round');
        welded.addAll(p);
      }
      // Объединяем раздельные куски, только если площадь сохраняется;
      // иначе численный union деградирует — оставляем отдельные части.
      List<Polygon2> finalSolid;
      final sumBefore = welded.fold(0.0, (a, p) => a + p.area);
      final merged = unaryUnionPolygons(welded);
      final sumAfter = merged.fold(0.0, (a, p) => a + p.area);
      if (sumAfter >= sumBefore - 0.01) {
        finalSolid = merged;
      } else {
        finalSolid = welded;
      }
      _extractPolygons(finalSolid, healed);
    }

    // === 4. ОСТАВШИЕСЯ ОТКРЫТЫЕ ЛИНИИ («ХВОСТЫ») ===
    final atomics = nodeLineSegments(snapped);
    List<List<Vec2>> remaining;
    if (polygons.isNotEmpty) {
      // Разность: атомарные сегменты минус рёбра внешних контуров граней.
      final boundary = <List<Vec2>>[];
      for (final poly in polygons) {
        final outer = cleanRing(poly.outerRing);
        if (outer.length < 2) continue;
        for (var i = 0; i < outer.length; i++) {
          boundary.add([outer[i], outer[(i + 1) % outer.length]]);
        }
      }
      remaining = <List<Vec2>>[];
      if (boundary.isNotEmpty) {
        // Индекс границы по сетке: проверка «лежит ли середина отрезка на
        // грани» только в соседних ячейках вместо полного перебора граней.
        final boundaryGrid = _BoundaryGrid(boundary);
        for (final seg in atomics) {
          if (!boundaryGrid.covered(seg)) remaining.add(seg);
        }
      } else {
        remaining = List.of(atomics);
      }
    } else {
      remaining = List.of(atomics);
    }

    if (remaining.isNotEmpty) {
      final mergedTails = lineMerge(remaining);
      for (final tail in mergedTails) {
        if (_polylineLength(tail) >= minLoopArea) {
          healed.add(CamPath(_round4(tail),
              isClosed: false, layerName: 'HEALED_TAIL'));
        }
      }
    }

    return healed;
  }

  // ============================================================
  // Внутреннее
  // ============================================================

  void _extractPolygons(List<Polygon2> polys, List<CamPath> out) {
    for (final poly in polys) {
      if (poly.isEmpty || poly.rings.isEmpty) continue;
      final outer = cleanRing(poly.rings[0]);
      if (outer.length >= 3) {
        out.add(CamPath(_round4(outer),
            isClosed: true, layerName: 'HEALED_POLY'));
      }
      for (var i = 1; i < poly.rings.length; i++) {
        final hole = cleanRing(poly.rings[i]);
        if (hole.length >= 3) {
          out.add(CamPath(_round4(hole),
              isClosed: true, layerName: 'HEALED_HOLE'));
        }
      }
    }
  }

  /// Снаппинг концов: пары концов с расстоянием 0 < d ≤ tolerance
  /// заменяются на среднюю точку; почти замкнувшиеся линии замыкаются.
  List<List<Vec2>> _snapEndpoints(List<List<Vec2>> lines) {
    if (lines.isEmpty) return lines;
    final endpoints = <({Vec2 pt, int line, bool isStart})>[];
    for (var i = 0; i < lines.length; i++) {
      final c = lines[i];
      endpoints.add((pt: c.first, line: i, isStart: true));
      endpoints.add((pt: c.last, line: i, isStart: false));
    }
    for (var i = 0; i < endpoints.length; i++) {
      for (var j = i + 1; j < endpoints.length; j++) {
        final d = _dist(endpoints[i].pt, endpoints[j].pt);
        if (d > 0 && d <= tolerance) {
          final avg = Vec2(
              (endpoints[i].pt.x + endpoints[j].pt.x) / 2,
              (endpoints[i].pt.y + endpoints[j].pt.y) / 2);
          endpoints[i] = (pt: avg, line: endpoints[i].line, isStart: endpoints[i].isStart);
          endpoints[j] = (pt: avg, line: endpoints[j].line, isStart: endpoints[j].isStart);
        }
      }
    }
    final out = <List<Vec2>>[];
    for (var i = 0; i < lines.length; i++) {
      final coords = List<Vec2>.of(lines[i]);
      final startPt = endpoints.firstWhere(
          (e) => e.line == i && e.isStart).pt;
      final endPt = endpoints.firstWhere(
          (e) => e.line == i && !e.isStart).pt;
      coords[0] = startPt;
      coords[coords.length - 1] = endPt;
      if (_dist(coords[0], coords.last) < 1e-4) {
        coords[coords.length - 1] = coords[0];
      }
      out.add(coords);
    }
    return out;
  }

  List<Vec2> _round4(List<Vec2> pts) => pts
      .map((p) => Vec2(
          double.parse(p.x.toStringAsFixed(4)),
          double.parse(p.y.toStringAsFixed(4))))
      .toList();

  double _dist(Vec2 a, Vec2 b) => (a - b).length;

  double _polylineLength(List<Vec2> pts) {
    var l = 0.0;
    for (var i = 1; i < pts.length; i++) {
      l += _dist(pts[i - 1], pts[i]);
    }
    return l;
  }
}

/// Индекс отрезков границы по равномерной сетке: ответ «лежит ли точка на
/// грани» (расстояние < 1e-6) ищется только среди рёбер, чей bbox покрывает
/// ячейку точки и её соседей. Результат идентичен полному перебору: точка на
/// ребре всегда попадает в ячейку, покрытую bbox ребра (или в соседнюю —
/// только при вырожденном допуске 1e-6 у самого конца ребра).
class _BoundaryGrid {
  final List<List<Vec2>> _edges;
  final List<int> _empty = const [];
  double _ox = 0, _oy = 0, _cell = 1;
  int _nx = 1, _ny = 1;
  final Map<int, List<int>> _bucket = {};

  _BoundaryGrid(List<List<Vec2>> edges) : _edges = edges {
    if (edges.isEmpty) return;
    var minX = edges[0][0].x, maxX = edges[0][0].x;
    var minY = edges[0][0].y, maxY = edges[0][0].y;
    for (final e in edges) {
      for (final p in e) {
        if (p.x < minX) minX = p.x;
        if (p.x > maxX) maxX = p.x;
        if (p.y < minY) minY = p.y;
        if (p.y > maxY) maxY = p.y;
      }
    }
    final spanX = maxX - minX;
    final spanY = maxY - minY;
    var cell = math.max(spanX, spanY) / 256.0;
    if (cell < 1e-4) cell = 1e-4;
    var nx = math.max(1, (spanX / cell).ceil());
    var ny = math.max(1, (spanY / cell).ceil());
    const maxAxis = 2048;
    if (nx > maxAxis || ny > maxAxis) {
      final k = math.max(nx, ny) / maxAxis;
      cell *= k;
      nx = math.max(1, (spanX / cell).ceil());
      ny = math.max(1, (spanY / cell).ceil());
    }
    _ox = minX;
    _oy = minY;
    _cell = cell;
    _nx = nx;
    _ny = ny;

    for (var e = 0; e < edges.length; e++) {
      final a = edges[e][0], b = edges[e][1];
      final x0 = a.x < b.x ? a.x : b.x;
      final x1 = a.x < b.x ? b.x : a.x;
      final y0 = a.y < b.y ? a.y : b.y;
      final y1 = a.y < b.y ? b.y : a.y;
      final cx0 = (((x0 - minX) / cell).floor()).clamp(0, nx - 1);
      final cx1 = (((x1 - minX) / cell).floor()).clamp(0, nx - 1);
      final cy0 = (((y0 - minY) / cell).floor()).clamp(0, ny - 1);
      final cy1 = (((y1 - minY) / cell).floor()).clamp(0, ny - 1);
      for (var cy = cy0; cy <= cy1; cy++) {
        for (var cx = cx0; cx <= cx1; cx++) {
          final key = cy * nx + cx;
          (_bucket[key] ??= <int>[]).add(e);
        }
      }
    }
  }

  bool covered(List<Vec2> seg) {
    if (_edges.isEmpty) return false;
    final mid = Vec2((seg[0].x + seg[1].x) / 2, (seg[0].y + seg[1].y) / 2);
    final cx = (((mid.x - _ox) / _cell).floor()).clamp(0, _nx - 1);
    final cy = (((mid.y - _oy) / _cell).floor()).clamp(0, _ny - 1);
    for (var dy = -1; dy <= 1; dy++) {
      for (var dx = -1; dx <= 1; dx++) {
        final yy = cy + dy;
        final xx = cx + dx;
        if (xx < 0 || xx >= _nx || yy < 0 || yy >= _ny) continue;
        final list = _bucket[yy * _nx + xx] ?? _empty;
        for (final e in list) {
          if (pointSegmentDistance(mid, _edges[e][0], _edges[e][1]) < 1e-6) {
            return true;
          }
        }
      }
    }
    return false;
  }
}
