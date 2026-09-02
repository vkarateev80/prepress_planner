/// Булевы и структурные операции: lineMerge, polygonize, unaryUnion,
/// buffer. Чистый Dart (контракт agents/01_geometry.md).
///
/// Общий принцип: планарное разбиение (нодинг отрезков точками пересечений)
/// + обход полурёбер с удержанием грани слева → грани; сборка результата
/// отменой общих рёбер.
library;

import 'dart:math' as math;
import 'polygon2.dart';
import 'geom_ops.dart';
import '../model/vec2.dart';

// ============================================================
// lineMerge: сшивка цепочек по общим концам
// ============================================================

/// Сшивает цепочки, соединяющиеся концами (степень узла = 2), в более
/// длинные линии. Направление продолжения не важно — стыкуем конец→начало
/// с учётом разворота. Коллинеарные наложения не обрабатываются (вне scope).
List<List<Vec2>> lineMerge(List<List<Vec2>> lines) {
  final chains = <_Chain>[];
  for (final raw in lines) {
    final l = _stripClosedDup(raw);
    if (l.length >= 2) chains.add(_Chain(List.of(l)));
  }
  if (chains.isEmpty) return [];

  var changed = true;
  while (changed) {
    changed = false;
    // Карта «узел → список индексов концов цепей».
    final nodeMap = <(double, double), List<_EndRef>>{};
    for (var i = 0; i < chains.length; i++) {
      final c = chains[i];
      _addNode(nodeMap, c.pts.first, _EndRef(i, true));
      _addNode(nodeMap, c.pts.last, _EndRef(i, false));
    }
    // Узлы, где встречаются РОВНО два конца разных цепей — их можно сшить.
    for (final refs in nodeMap.values) {
      if (refs.length != 2) continue;
      final r1 = refs[0], r2 = refs[1];
      if (r1.chain == r2.chain) continue;
      final c1 = chains[r1.chain];
      final c2 = chains[r2.chain];
      // Проверка «не выродится ли»: не сшиваем, если одна цепь уже замкнута.
      if ((c1.pts.first - c1.pts.last).length < 1e-7) continue;
      if ((c2.pts.first - c2.pts.last).length < 1e-7) continue;

      List<Vec2> merged;
      if (r1.isStart && r2.isStart) {
        // общий узел — начало обеих: идём от конца c2 к началу c1
        merged = [...c2.pts.reversed, ...c1.pts.skip(1)];
      } else if (r1.isStart && !r2.isStart) {
        // общий узел — начало c1 и конец c2
        merged = [...c2.pts, ...c1.pts.skip(1)];
      } else if (!r1.isStart && r2.isStart) {
        // общий узел — конец c1 и начало c2
        merged = [...c1.pts, ...c2.pts.skip(1)];
      } else {
        // общий узел — конец обеих
        merged = [...c1.pts, ...c2.pts.reversed.skip(1)];
      }
      // Гарантированно не создаём пустых хвостов и дублей точек стыка.
      merged = _stripClosedDup(merged);
      if (merged.length < 2) continue;
      // Собираем новые цепи (удаляем обе, добавляем одну).
      final newChains = <_Chain>[];
      for (var i = 0; i < chains.length; i++) {
        if (i == r1.chain || i == r2.chain) continue;
        newChains.add(chains[i]);
      }
      newChains.add(_Chain(merged));
      chains
        ..clear()
        ..addAll(newChains);
      changed = true;
      break; // пересобрать карту узлов
    }
  }
  return chains.map((c) => c.pts).toList();
}

class _Chain {
  List<Vec2> pts;
  _Chain(this.pts);
}

class _EndRef {
  final int chain;
  final bool isStart;
  _EndRef(this.chain, this.isStart);
}

void _addNode(Map<(double, double), List<_EndRef>> map, Vec2 p, _EndRef ref) {
  final key = ((p.x * 1e6).roundToDouble(), (p.y * 1e6).roundToDouble());
  map.putIfAbsent(key, () => []).add(ref);
}

List<Vec2> _stripClosedDup(List<Vec2> pts) {
  final out = <Vec2>[];
  for (final p in pts) {
    if (out.isEmpty || (out.last - p).length > 1e-7) out.add(p);
  }
  if (out.length >= 2 && (out.first - out.last).length < 1e-7) {
    out.removeLast();
  }
  return out;
}

// ============================================================
// Планарный граф и грани
// ============================================================

class _Node {
  final Vec2 p;
  final List<_Arc> out = [];
  _Node(this.p);
}

class _Arc {
  final _Node from;
  final _Node to;
  double angle = 0;
  bool used = false;
  _Arc(this.from, this.to);
}

/// Все отрезки из списка ломаных. Явный дубль первой точки в конце НЕ
/// удаляется — он даёт замыкающий сегмент (кольца, у которых первая точка
/// повторена, обязаны замкнуться).
List<List<Vec2>> _segmentsOf(List<List<Vec2>> lines) {
  final segs = <List<Vec2>>[];
  for (final line in lines) {
    if (line.length < 2) continue;
    for (var i = 0; i + 1 < line.length; i++) {
      final a = line[i], b = line[i + 1];
      if ((a - b).length > 1e-9) segs.add([a, b]);
    }
  }
  return segs;
}

/// Нодинг: разбиение отрезков точками пересечений; возвращает полудуги
/// планарного графа (по две на атомарное ребро).
List<_Arc> _nodeSegments(List<List<Vec2>> segs) {
  // Сначала snap: объединяем совпадающие концы (для замыкания контуров).
  final nodes = <_Node>[];
  final nodeKey = <(double, double), _Node>{};
  _Node nodeAt(Vec2 p) {
    final k = ((p.x * 1e6).roundToDouble(), (p.y * 1e6).roundToDouble());
    return nodeKey.putIfAbsent(k, () {
      final n = _Node(Vec2(p.x, p.y));
      nodes.add(n);
      return n;
    });
  }

  // Разбиваем каждый отрезок всеми точками пересечения с другими.
  final result = <List<Vec2>>[];
  for (var i = 0; i < segs.length; i++) {
    final a1 = segs[i][0], a2 = segs[i][1];
    final cuts = <double>[
      0.0,
      1.0
    ];
    for (var j = 0; j < segs.length; j++) {
      if (i == j) continue;
      final b1 = segs[j][0], b2 = segs[j][1];
      final inter = segmentIntersections(a1, a2, b1, b2);
      for (final x in inter) {
        final d1 = (x - a1).length, d2 = (x - a2).length;
        final total = d1 + d2;
        if (total < 1e-9) continue;
        final t = d1 / total;
        if (t > 1e-9 && t < 1 - 1e-9) cuts.add(t);
      }
    }
    cuts.sort();
    for (var k = 0; k + 1 < cuts.length; k++) {
      final t1 = cuts[k], t2 = cuts[k + 1];
      if (t2 - t1 < 1e-9) continue;
      final u = a1 + (a2 - a1) * t1;
      final v = a1 + (a2 - a1) * t2;
      if ((u - v).length < 1e-7) continue;
      result.add([u, v]);
    }
  }

  // Строим узлы/дуги.
  final arcs = <_Arc>[];
  for (final e in result) {
    final n1 = nodeAt(e[0]);
    final n2 = nodeAt(e[1]);
    final a = _Arc(n1, n2);
    final b = _Arc(n2, n1);
    a.angle = math.atan2(n2.p.y - n1.p.y, n2.p.x - n1.p.x);
    b.angle = math.atan2(n1.p.y - n2.p.y, n1.p.x - n2.p.x);
    n1.out.add(a);
    n2.out.add(b);
    arcs.add(a);
    arcs.add(b);
  }
  return arcs;
}

/// Обход граней: каждая ограниченная грань — CCW-кольцо (площадь > 0);
/// внешняя (неограниченная) грань выходит CW и отбрасывается.
List<List<Vec2>> _traceFaces(List<_Arc> arcs) {
  final faces = <List<Vec2>>[];
  for (final start in arcs) {
    if (start.used) continue;
    final ring = <Vec2>[];
    _Arc? cur = start;
    var guard = 0;
    while (cur != null && guard < 1e6) {
      cur.used = true;
      ring.add(cur.from.p);
      // Грань слева от cur: следующая дуга — с минимальным ПРАВЫМ поворотом
      // от обратного направления (возврат по той же линии исключаем).
      final rev = (cur.angle + math.pi) % (2 * math.pi);
      _Arc? best;
      var bestTurn = double.infinity;
      for (final cand in cur.to.out) {
        var turn = (rev - cand.angle) % (2 * math.pi);
        if (turn < 1e-12) continue; // строго назад — обратная дуга
        if (turn < bestTurn) {
          bestTurn = turn;
          best = cand;
        }
      }
      if (best == null || best.used || identical(best, start)) break;
      cur = best;
      guard++;
    }
    if (ring.length >= 3) {
      final a = ringArea(ring);
      if (a > 1e-9) faces.add(ring); // ограниченные грани — CCW
    }
  }
  return faces;
}

/// Полигонизация ломаных: грани планарного графа.
List<Polygon2> polygonize(List<List<Vec2>> lines) {
  final segs = _segmentsOf(lines);
  if (segs.isEmpty) return const [];
  final arcs = _nodeSegments(segs);
  if (arcs.isEmpty) return const [];
  final faces = _traceFaces(arcs);
  return faces.map((f) => Polygon2([f])).toList();
}

// ============================================================
// unaryUnion полигонов
// ============================================================

/// Покрыта ли точка полигоном (внешнее кольцо содержит, ни одно отверстие).
bool _coveredBy(Vec2 p, Polygon2 poly) {
  if (poly.rings.isEmpty) return false;
  if (!pointInRing(p, poly.rings[0])) return false;
  for (var i = 1; i < poly.rings.length; i++) {
    if (pointInRing(p, poly.rings[i])) return false;
  }
  return true;
}

/// Булево объединение полигонов (пересекающихся, смежных, с отверстиями).
List<Polygon2> unaryUnionPolygons(List<Polygon2> input) {
  final polys = input.where((p) => !p.isEmpty).toList();
  if (polys.isEmpty) return const [];
  if (polys.length == 1) return [polys[0]];

  // 1. Все рёбра всех колец → грани.
  final allLines = <List<Vec2>>[];
  for (final p in polys) {
    for (final ring in p.rings) {
      final r = _stripClosedDup(ring);
      if (r.length < 3) continue;
      final closed = List<Vec2>.of(r)..add(r.first);
      allLines.add(closed);
    }
  }
  final arcs = _nodeSegments(_segmentsOf(allLines));
  final faces = _traceFaces(arcs);
  if (faces.isEmpty) return const [];

  // 2. Отбираем грани, покрытые объединением (центроид внутри хотя бы одного).
  final selected = <List<Vec2>>[];
  for (final f in faces) {
    final c = ringCentroid(f);
    if (polys.any((p) => _coveredBy(c, p))) selected.add(f);
  }
  if (selected.isEmpty) return const [];

  // 3. Отменяем общие рёбра выбранных граней.
  final edgeCount = <String, int>{};
  final edgePt = <String, List<Vec2>>{};
  void addEdge(Vec2 u, Vec2 v) {
    final k = '${(u.x * 1e6).round()},${(u.y * 1e6).round()}|${(v.x * 1e6).round()},${(v.y * 1e6).round()}';
    edgeCount[k] = (edgeCount[k] ?? 0) + 1;
    edgePt[k] = [u, v];
  }

  for (final f in selected) {
    final n = f.length;
    for (var i = 0; i < n; i++) {
      addEdge(f[i], f[(i + 1) % n]);
    }
  }
  final rev = <String, String>{};
  edgePt.forEach((k, v) {
    final rk = '${(v[1].x * 1e6).round()},${(v[1].y * 1e6).round()}|${(v[0].x * 1e6).round()},${(v[0].y * 1e6).round()}';
    rev[k] = rk;
  });

  // Граничные рёбра: те, чей reverse не встречается.
  final boundary = <List<Vec2>>[];
  edgePt.forEach((k, v) {
    final cnt = edgeCount[k] ?? 0;
    final rcnt = edgeCount[rev[k]] ?? 0;
    if (cnt > rcnt) {
      // Оставляем (cnt − rcnt) экземпляров.
      for (var t = 0; t < cnt - rcnt; t++) {
        boundary.add(v);
      }
    }
  });
  if (boundary.isEmpty) return const [];

  // 4. Трассируем граничные рёбра в кольца.
  final byStart = <String, List<List<Vec2>>>{};
  for (final e in boundary) {
    final k = '${(e[0].x * 1e6).round()},${(e[0].y * 1e6).round()}';
    byStart.putIfAbsent(k, () => []).add(e);
  }
  final usedB = List<bool>.filled(boundary.length, false);
  final ringsOut = <List<Vec2>>[];
  for (var i = 0; i < boundary.length; i++) {
    if (usedB[i]) continue;
    final ring = <Vec2>[];
    var cur = boundary[i];
    var guard = 0;
    while (guard < 1e6) {
      usedB[i] = true;
      ring.add(cur[0]);
      final k = '${(cur[1].x * 1e6).round()},${(cur[1].y * 1e6).round()}';
      final cands = byStart[k];
      List<Vec2>? next;
      if (cands != null) {
        for (var cIdx = 0; cIdx < cands.length; cIdx++) {
          final e2 = cands[cIdx];
          final eIdx = boundary.indexOf(e2);
          if (eIdx >= 0 && !usedB[eIdx]) {
            next = e2;
            usedB[eIdx] = true;
            break;
          }
        }
      }
      if (next == null) break;
      if (identical(next, cur)) break;
      cur = next;
      if ((cur[0] - ring.first).length < 1e-7) break;
      guard++;
    }
    if (ring.length >= 3 && ringArea(ring).abs() > 1e-9) {
      ringsOut.add(ring);
    }
  }

  // 5. Разделяем внешние (CCW) и отверстия (CW), вкладываем отверстия.
  final outers = <List<Vec2>>[];
  final holes = <List<Vec2>>[];
  for (final r in ringsOut) {
    if (ringArea(r) > 0) {
      outers.add(r);
    } else {
      holes.add(r);
    }
  }
  final result = <Polygon2>[];
  for (final o in outers) {
    final myHoles = <List<Vec2>>[];
    for (final h in holes) {
      final c = ringCentroid(h);
      if (pointInRing(c, o)) myHoles.add(h);
    }
    result.add(Polygon2([o, ...myHoles]));
  }
  // Осиротевшие отверстия (внешняя геометрия странная) — игнорируем.
  return result;
}

// ============================================================
// buffer (офсет полигона)
// ============================================================

/// Офсет полигонов на [distance] (мм). Отрицательное значение — эрозия.
/// join: 'round' (по умолчанию, как у shapely), 'miter', 'bevel'.
/// После офсета результаты объединяются (unaryUnionPolygons).
List<Polygon2> bufferPolygons(List<Polygon2> input, double distance,
    {String join = 'round', double mitreLimit = 5.0}) {
  if (input.isEmpty || distance.abs() < 1e-12) {
    return input.where((p) => !p.isEmpty).toList();
  }
  final out = <Polygon2>[];
  for (final p in input) {
    if (p.isEmpty) continue;
    final oriented = normalizeRings(p);
    if (oriented.isEmpty) continue;
    final newOuter = _offsetRing(oriented[0], distance, join, mitreLimit, isHole: false);
    if (newOuter == null || ringArea(newOuter).abs() <= 1e-9) continue;
    // Нормализуем внешний результат: CCW.
    final outer = ringArea(newOuter) < 0 ? newOuter.reversed.toList() : newOuter;
    final holes = <List<Vec2>>[];
    for (var i = 1; i < oriented.length; i++) {
      final h = _offsetRing(oriented[i], distance, join, mitreLimit, isHole: true);
      if (h == null || ringArea(h).abs() <= 1e-9) continue;
      if (ringArea(h) > 0) {
        holes.add(h.reversed.toList()); // CW
      } else {
        holes.add(h);
      }
    }
    out.add(Polygon2([outer, ...holes]));
  }
  if (out.length <= 1) return out;
  return unaryUnionPolygons(out);
}

/// Офсет одного кольца. Кольцо ориентировано: внешнее CCW, отверстие CW.
/// Сдвиг на +d вправо от направления обхода (расширяет внешнее, сжимает
/// отверстие); отрицательный d — наоборот.
List<Vec2>? _offsetRing(List<Vec2> ring, double d, String join, double mitreLimit,
    {required bool isHole}) {
  var pts = _stripClosedDup(ring);
  if (pts.length < 3) return null;
  final wantCcw = !isHole;
  final s = ringArea(pts);
  if ((s > 0) != wantCcw) pts = pts.reversed.toList();

  final n = pts.length;
  final starts = List<Vec2>.filled(n, const Vec2(0, 0));
  final ends = List<Vec2>.filled(n, const Vec2(0, 0));
  for (var i = 0; i < n; i++) {
    final a = pts[i];
    final b = pts[(i + 1) % n];
    final dx = b.x - a.x, dy = b.y - a.y;
    final len = math.sqrt(dx * dx + dy * dy);
    if (len < 1e-12) continue;
    final nx = dy / len * d; // правая нормаль (dy, −dx)/len × d
    final ny = -dx / len * d;
    starts[i] = Vec2(a.x + nx, a.y + ny);
    ends[i] = Vec2(b.x + nx, b.y + ny);
  }

  // Последовательность вершин офсета: для каждого угла pts[j] — либо
  // miter-точка (острый угол), либо [конец пред. ребра + дуга + начало след.
  // ребра] (round при расширении у выпуклого угла, правило GEOS).
  final orientSign = ringArea(pts) >= 0 ? 1.0 : -1.0; // CCW:+1, CW:−1
  final out = <Vec2>[];
  for (var j = 0; j < n; j++) {
    final prev = (j - 1 + n) % n;
    final nxt = (j + 1) % n;
    final a = ends[prev]; // конец смещённого ребра (prev→j)
    final b = starts[j]; // начало смещённого ребра (j→nxt)
    final cross = (pts[j] - pts[prev]).cross(pts[nxt] - pts[j]);
    final convex = orientSign > 0 ? cross > 0 : cross < 0;
    final expand = isHole ? -d : d; // расширение области кольца
    final wantArc = join == 'round' && expand > 0 && convex && (b - a).length > 1e-9;
    if (wantArc) {
      out.add(a);
      out.addAll(_roundJoin(pts[prev], pts[j], pts[nxt], a, b, d));
      out.add(b);
      continue;
    }
    // Острый угол: точка пересечения смещённых прямых (miter), иначе bevel.
    final m = _miterPoint(pts[prev], pts[j], pts[nxt], a, b, d, mitreLimit);
    if (m != null) {
      out.add(m);
    } else {
      out.add(a);
      if ((b - a).length > 1e-9) out.add(b);
    }
  }
  // Замыкание: последняя точка должна совпасть с первой (убираем дубль).
  var res = _stripClosedDup(out);
  if (res.length < 3) return null;
  return res;
}

/// Дуга round-join на угле pts[j] от a (конец смещённого ребра i) к b
/// (начало смещённого ребра j). Направление обхода — по знаку локального
/// поворота (cross) кольца; размах — минимальный угол между лучами к a и b.
List<Vec2> _roundJoin(Vec2 p, Vec2 v, Vec2 n, Vec2 a, Vec2 b, double d) {
  final r = d.abs();
  if (r < 1e-12) return const [];
  double ang(Vec2 q) {
    var t = math.atan2(q.y - v.y, q.x - v.x) % (2 * math.pi);
    if (t < 0) t += 2 * math.pi;
    return t;
  }

  final da = ang(a);
  final db = ang(b);
  final diff = (db - da) % (2 * math.pi);
  var delta = diff > math.pi ? 2 * math.pi - diff : diff;
  if (delta < 1e-9) return const [];
  final cross = (v - p).cross(n - v);
  final sweep = (cross >= 0 ? 1.0 : -1.0) * delta;
  final steps = math.max(2, math.min(48, (delta / (math.pi / 24)).ceil()));
  final out = <Vec2>[];
  for (var k = 1; k < steps; k++) {
    final ang = da + sweep * k / steps;
    out.add(Vec2(v.x + r * math.cos(ang), v.y + r * math.sin(ang)));
  }
  return out;
}

Vec2? _miterPoint(Vec2 pa, Vec2 vtx, Vec2 pb, Vec2 a, Vec2 b, double d, double mitreLimit) {
  // Пересечение прямых: через a с направлением (vtx−pa) и через b с (pb−vtx).
  final dir1 = vtx - pa;
  final dir2 = pb - vtx;
  final denom = dir1.cross(dir2);
  if (denom.abs() < 1e-12) return null;
  final t = (b - a).cross(dir2) / denom;
  final m = a + dir1 * t;
  if ((m - vtx).length > d.abs() * mitreLimit + 1e-9) return null; // bevel-фолбэк
  return m;
}

