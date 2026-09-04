/// Проверки геометрии на технологичность (порт cam_material
/// src/manufacturability/geometry_checks.py, 1:1).
///
/// Каждая функция возвращает список Issue с kind/severity/points/message/
/// suggestion/index. severity — ТОЧНО как в Python:
///   open -> error, dust/intersection/duplicate/small_gap -> warning,
///   sharp_corner -> error ИЛИ suggestion (по r_max).
/// Порядок сборки отчёта и русские тексты — как в analyzer.py + geometry_checks.py.
library;

import 'dart:math' as math;

import '../model/cam_path.dart';
import '../model/vec2.dart';
import '../model/issue.dart';
import '../geom/geom_ops.dart' show ringAreaAbs, pointSegmentDistance;

// ============================================================
// Внутренние помощники
// ============================================================

const Set<String> _fixableKinds = {'dust', 'open', 'intersection', 'duplicate'};

Issue _issue(String kind, String severity, List<Vec2> pts, String message,
        String suggestion, int index) =>
    Issue(
      kind: kind,
      severity: severity,
      points: pts,
      message: message,
      suggestion: suggestion,
      fixable: _fixableKinds.contains(kind),
      index: index,
    );

double _length(List<Vec2> pts) {
  var l = 0.0;
  for (var i = 1; i < pts.length; i++) {
    l += (pts[i] - pts[i - 1]).length;
  }
  return l;
}

String _fmt2(double v) => v.toStringAsFixed(2);
String _fmt3(double v) => v.toStringAsFixed(3);
String _fmt0(double v) => v.toStringAsFixed(0);

Vec2 _round3(Vec2 v) =>
    Vec2(double.parse(v.x.toStringAsFixed(3)), double.parse(v.y.toStringAsFixed(3)));

/// Сегмент-сегмент: пересечение как у Shapely `segments[k].intersection(...)`.
/// Возвращает точки пересечения (маркеры) и длину общей части
/// (0 для точечных касаний/пересечений; > 0 для коллинеарного перекрытия).
({List<Vec2> pts, double overlap}) _segPair(
    Vec2 a1, Vec2 a2, Vec2 b1, Vec2 b2) {
  final r = a2 - a1;
  final s = b2 - b1;
  final denom = r.cross(s);
  final qp = b1 - a1;
  if (denom.abs() < 1e-12) {
    // Параллельны или коллинеарны.
    if (qp.cross(r).abs() >= 1e-9) return (pts: const [], overlap: 0);
    final rl2 = r.lengthSquared;
    if (rl2 < 1e-18) return (pts: const [], overlap: 0);
    double proj(Vec2 p) => (p - a1).dot(r) / rl2;
    var t0 = proj(b1);
    var t1 = proj(b2);
    var lo = t0 < t1 ? t0 : t1;
    var hi = t0 < t1 ? t1 : t0;
    if (lo < 0) lo = 0;
    if (hi > 1) hi = 1;
    if (hi < lo - 1e-9) return (pts: const [], overlap: 0);
    if ((hi - lo).abs() < 1e-9) {
      return (pts: [a1 + r * lo], overlap: 0); // касание в точке
    }
    return (pts: [a1 + r * lo, a1 + r * hi], overlap: (hi - lo) * r.length);
  }
  final t = qp.cross(s) / denom;
  final u = qp.cross(r) / denom;
  if (t < -1e-9 || t > 1 + 1e-9 || u < -1e-9 || u > 1 + 1e-9) {
    return (pts: const [], overlap: 0);
  }
  return (pts: [a1 + r * t], overlap: 0);
}

// ============================================================
// Пыль (мелкие контуры/штрихи)
// ============================================================

/// Проверка «пыли»: замкнутый контур с площадью < minLoopArea мм²
/// или разомкнутый штрих длиной < minLoopArea мм.
bool isDust(CamPath path, double minLoopArea) {
  final pts = path.points;
  if (pts.length < 2 || minLoopArea <= 0) return false;
  final closed = path.isClosed || (pts.first - pts.last).length < 1e-9;
  if (closed) {
    // Аналог Polygon(line.coords).area < min_loop_area (except -> True).
    final ring = <Vec2>[];
    for (final p in pts) {
      if (ring.isEmpty || (ring.last - p).length > 1e-9) ring.add(p);
    }
    if (ring.length < 3) return true; // не собирается в полигон — битый мусор
    return ringAreaAbs(ring) < minLoopArea;
  }
  return _length(pts) < minLoopArea;
}

List<Issue> checkDust(List<CamPath> paths, double minLoopArea) {
  final issues = <Issue>[];
  for (var i = 0; i < paths.length; i++) {
    final path = paths[i];
    if (!isDust(path, minLoopArea)) continue;
    final pts = path.points;
    final markers = <Vec2>[pts[0], pts[1]];
    issues.add(_issue(
      'dust',
      'warning',
      markers,
      'Пыль/мусор: контур №${i + 1} меньше ${_fmt2(minLoopArea)} мм².',
      'Удалить этот контур (автоматически).',
      i,
    ));
  }
  return issues;
}

// ============================================================
// Разомкнутые контуры
// ============================================================

List<Issue> checkOpenPaths(List<CamPath> paths) {
  final issues = <Issue>[];
  for (var i = 0; i < paths.length; i++) {
    final path = paths[i];
    if (path.points.length < 2) continue;
    if (!path.isClosed) {
      issues.add(_issue(
        'open',
        'error',
        [path.points.first, path.points.last],
        'Разомкнутый контур №${i + 1}: концы не сходятся.',
        'Замкнуть контур (морфологическое лечение).',
        i,
      ));
    }
  }
  return issues;
}

// ============================================================
// Пересечения и дубликаты сегментов
// ============================================================

/// Соседи по сетке: для каждого сегмента i — список j, чей bbox пересекается
/// с bbox i (кандидаты на пересечение). Результат ПОБИТОВО тот же, что у
/// полного перебора: не пересекающиеся по bbox сегменты точно не имеют общих
/// точек; каждый сегмент добавлен во все ячейки своего bbox, поэтому любая
/// пара с пересекающимися bbox обязательно попадёт в общую ячейку. Сетка лишь
/// убирает заведомо пустые пары — это ускоряет проверки на контурах с
/// десятками тысяч точек (иначе O(N²) не укладывается в таймаут анализа).
List<List<int>> _overlapNeighbors(List<List<Vec2>> segs) {
  final n = segs.length;
  final out = List.generate(n, (_) => <int>[]);
  if (n < 2) return out;

  final bxs = List<double>.filled(n, 0);
  final bys = List<double>.filled(n, 0);
  final bxe = List<double>.filled(n, 0);
  final bye = List<double>.filled(n, 0);
  var minX = double.infinity, maxX = double.negativeInfinity;
  var minY = double.infinity, maxY = double.negativeInfinity;
  for (var i = 0; i < n; i++) {
    final a = segs[i][0], b = segs[i][1];
    final x0 = a.x < b.x ? a.x : b.x;
    final x1 = a.x < b.x ? b.x : a.x;
    final y0 = a.y < b.y ? a.y : b.y;
    final y1 = a.y < b.y ? b.y : a.y;
    bxs[i] = x0;
    bys[i] = y0;
    bxe[i] = x1;
    bye[i] = y1;
    if (x0 < minX) minX = x0;
    if (x1 > maxX) maxX = x1;
    if (y0 < minY) minY = y0;
    if (y1 > maxY) maxY = y1;
  }
  final spanX = maxX - minX;
  final spanY = maxY - minY;
  const targetCells = 256.0;
  var cell = math.max(spanX, spanY) / targetCells;
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

  final buckets = <int, List<int>>{};
  for (var i = 0; i < n; i++) {
    final cx0 = (((bxs[i] - minX) / cell).floor()).clamp(0, nx - 1);
    final cx1 = (((bxe[i] - minX) / cell).floor()).clamp(0, nx - 1);
    final cy0 = (((bys[i] - minY) / cell).floor()).clamp(0, ny - 1);
    final cy1 = (((bye[i] - minY) / cell).floor()).clamp(0, ny - 1);
    for (var cy = cy0; cy <= cy1; cy++) {
      for (var cx = cx0; cx <= cx1; cx++) {
        final key = cy * nx + cx;
        (buckets[key] ??= <int>[]).add(i);
      }
    }
  }

  final seen = <int>{};
  for (final list in buckets.values) {
    final k = list.length;
    for (var p = 0; p < k; p++) {
      final i = list[p];
      for (var q = p + 1; q < k; q++) {
        final j = list[q];
        if (bxe[i] < bxs[j] - 1e-9 ||
            bxe[j] < bxs[i] - 1e-9 ||
            bye[i] < bys[j] - 1e-9 ||
            bye[j] < bys[i] - 1e-9) {
          continue;
        }
        final key = i < j ? i * n + j : j * n + i;
        if (seen.add(key)) {
          out[i].add(j);
          out[j].add(i);
        }
      }
    }
  }
  return out;
}

List<Issue> checkIntersectionsDuplicates(List<CamPath> paths) {
  final issues = <Issue>[];
  final polys = <({int idx, List<Vec2> pts})>[];
  for (var i = 0; i < paths.length; i++) {
    if (paths[i].points.length < 2) continue;
    polys.add((idx: i, pts: paths[i].points));
  }
  if (polys.isEmpty) return issues;
  final P = polys.length;

  // Глобальный индекс всех сегментов по bbox-сетке (см. _overlapNeighbors):
  // проверяются только пары с пересекающимися bbox — результаты те же, что
  // у полного перебора, но на контурах-гигантах (десятки тысяч точек) время
  // падает с квадратичного до почти линейного.
  final segs = <List<Vec2>>[];
  final segPath = <int>[];
  final segLocal = <int>[];
  for (var a = 0; a < P; a++) {
    final pts = polys[a].pts;
    for (var k = 0; k + 1 < pts.length; k++) {
      segs.add([pts[k], pts[k + 1]]);
      segPath.add(a);
      segLocal.add(k);
    }
  }
  final neighbors = _overlapNeighbors(segs);

  // 1. Самопересечения внутри одного контура.
  // Собираем пары-кандидаты по каждому контуру и выдаём в порядке (k, m)
  // исходного перебора, чтобы список проблем не изменился.
  final pathClosed = [
    for (final c in polys) (c.pts.first - c.pts.last).length < 1e-4
  ];
  final selfByPath = List.generate(P, (_) => <(int, int)>[]);
  for (var i = 0; i < segs.length; i++) {
    final a = segPath[i];
    final n = polys[a].pts.length;
    for (final j in neighbors[i]) {
      if (j <= i || segPath[j] != a) continue;
      final k = segLocal[i], m = segLocal[j];
      if (m < k + 2) continue; // соседние сегменты делят вершину
      if (pathClosed[a] && k == 0 && m == n - 2) continue; // замыкание кольца
      selfByPath[a].add((i, j));
    }
  }
  for (var a = 0; a < P; a++) {
    final pairs = selfByPath[a];
    if (pairs.isEmpty) continue;
    pairs.sort((x, y) => x.$1 != y.$1 ? x.$1 - y.$1 : x.$2 - y.$2);
    for (final (i, j) in pairs) {
      final a1 = segs[i][0], a2 = segs[i][1];
      final b1 = segs[j][0], b2 = segs[j][1];
      if ((a1 - a2).length < 1e-12 || (b1 - b2).length < 1e-12) continue;
      final res = _segPair(a1, a2, b1, b2);
      if (res.pts.isEmpty) continue;
      if (res.overlap > 0.01) {
        issues.add(_issue(
          'duplicate',
          'warning',
          res.pts,
          'Дубликат сегментов в контуре №${polys[a].idx + 1}.',
          'Нормализовать геометрию (лечение).',
          polys[a].idx,
        ));
      } else {
        issues.add(_issue(
          'intersection',
          'warning',
          res.pts,
          'Самопересечение в контуре №${polys[a].idx + 1}.',
          'Нормализовать геометрию (лечение).',
          polys[a].idx,
        ));
      }
    }
  }

  // 2. Пересечения/дубликаты между разными контурами (одна проблема на пару
  // контуров, как в оригинале: дубликат при суммарном перекрытии > 0.01).
  final pairHits = <int, ({List<Vec2> pts, double overlap})>{};
  for (var i = 0; i < segs.length; i++) {
    final a = segPath[i];
    final a1 = segs[i][0], a2 = segs[i][1];
    for (final j in neighbors[i]) {
      if (j <= i) continue;
      final b = segPath[j];
      if (a == b) continue;
      final lo = a < b ? a : b;
      final hi = a < b ? b : a;
      final key = lo * P + hi;
      final b1 = segs[j][0], b2 = segs[j][1];
      if ((a1 - a2).length < 1e-12 || (b1 - b2).length < 1e-12) continue;
      final res = _segPair(a1, a2, b1, b2);
      if (res.pts.isEmpty) continue;
      final cur = pairHits[key];
      if (cur == null) {
        pairHits[key] = (pts: List<Vec2>.of(res.pts), overlap: res.overlap);
      } else {
        cur.pts.addAll(res.pts);
        pairHits[key] = (pts: cur.pts, overlap: cur.overlap + res.overlap);
      }
    }
  }
  for (var a = 0; a < P; a++) {
    for (var b = a + 1; b < P; b++) {
      final hit = pairHits[a * P + b];
      if (hit == null) continue;
      if (hit.overlap > 0.01) {
        issues.add(_issue(
          'duplicate',
          'warning',
          hit.pts,
          'Дубликат: контуры №${polys[a].idx + 1} и №${polys[b].idx + 1}.',
          'Нормализовать геометрию (лечение).',
          polys[a].idx,
        ));
      } else {
        issues.add(_issue(
          'intersection',
          'warning',
          hit.pts,
          'Пересечение контуров №${polys[a].idx + 1} и №${polys[b].idx + 1}.',
          'Нормализовать геометрию (лечение).',
          polys[a].idx,
        ));
      }
    }
  }
  return issues;
}

// ============================================================
// Острые внутренние углы
// ============================================================
// Эвристика (1:1 из Python): разворот лезвия > 90° -> угол острый;
// r_max = min(длин сторон)·tan(wedge/2) — помещается ли скругление
// радиусом minRadius; r_max < minRadius -> error, иначе suggestion.

List<Issue> checkSharpCorners(List<CamPath> paths, double minRadius) {
  final issues = <Issue>[];
  if (minRadius <= 0) return issues;
  for (var i = 0; i < paths.length; i++) {
    final pts = paths[i].points;
    final n = pts.length;
    if (n < 3) continue;
    final area = _signedArea(pts);
    for (var j = 0; j < n; j++) {
      final b = pts[j];
      final a = pts[(j - 1) % n];
      final c = pts[(j + 1) % n];

      final vIn = b - a;
      final vOut = c - b;
      final lIn = vIn.length;
      final lOut = vOut.length;
      if (lIn < 1e-6 || lOut < 1e-6) continue;

      var dot = vIn.dot(vOut) / (lIn * lOut);
      if (dot < -1.0) dot = -1.0;
      if (dot > 1.0) dot = 1.0;
      final beta = math.acos(dot); // угол разворота векторов (0..pi)

      final cross = vIn.cross(vOut);
      final isConvex = (cross > 0) == (area > 0);
      final theta = isConvex ? math.pi - beta : math.pi + beta; // внутр. угол

      final turnDeg = (math.pi - theta).abs() * 180.0 / math.pi;
      if (turnDeg <= 90.0) continue;

      final wedge = math.min(theta, 2 * math.pi - theta); // угол «клина»
      final rMax = math.min(lIn, lOut) * math.tan(wedge / 2.0);

      final pt = _round3(b);
      if (rMax < minRadius) {
        issues.add(_issue(
          'sharp_corner',
          'error',
          [pt],
          'Острый угол в контуре №${i + 1}: скругление радиусом '
              '${_fmt2(minRadius)} мм не помещается (макс. ${_fmt3(rMax)} мм).',
          'Переработать угол: увеличить угол или длину прилегающих сторон.',
          i,
        ));
      } else {
        issues.add(_issue(
          'sharp_corner',
          'suggestion',
          [pt],
          'Острый угол в контуре №${i + 1} (разворот ${_fmt0(turnDeg)}°).',
          'Скруглить внутренний угол радиусом не менее ${_fmt2(minRadius)} мм.',
          i,
        ));
      }
    }
  }
  return issues;
}

double _signedArea(List<Vec2> pts) {
  var s = 0.0;
  for (var k = 0; k < pts.length - 1; k++) {
    s += pts[k].x * pts[k + 1].y - pts[k + 1].x * pts[k].y;
  }
  return s / 2.0;
}

// ============================================================
// Малые зазоры между контурами
// ============================================================

/// Метрика пары сегментов: расстояние и ближайшие точки (аналог внутренней
/// логики _linesDistance + _nearestPoints для одной пары).
({double d, Vec2 p1, Vec2 p2}) _pairMetrics(
    Vec2 a1, Vec2 a2, Vec2 b1, Vec2 b2) {
  final hit = _segPair(a1, a2, b1, b2);
  if (hit.pts.isNotEmpty) return (d: 0.0, p1: hit.pts.first, p2: hit.pts.first);
  var best = double.infinity;
  Vec2 q1 = a1, q2 = b1;
  void upd(double dv, Vec2 u, Vec2 v) {
    if (dv < best) {
      best = dv;
      q1 = u;
      q2 = v;
    }
  }

  final onB1 = _proj(a1, b1, b2);
  upd((a1 - onB1).length, onB1, a1);
  final onB2 = _proj(a2, b1, b2);
  upd((a2 - onB2).length, onB2, a2);
  final onA1 = _proj(b1, a1, a2);
  upd((b1 - onA1).length, b1, onA1);
  final onA2 = _proj(b2, a1, a2);
  upd((b2 - onA2).length, b2, onA2);
  return (d: best, p1: q1, p2: q2);
}

/// Пары сегментов двух контуров, чьи bbox-ы разнесены по осям меньше [near]
/// (сетка с ячейкой [near], соседство радиуса 1). Гарантированное
/// НАДмножество пар с расстоянием < [near] (сами расстояния проверяются
/// дальше точно) — для гигантских контуров это заменяет квадратичный
/// перебор O(Sa×Sb) почти линейным.
List<(int, int)> _nearSegmentPairs(List<List<Vec2>> segsAll, double near) {
  final n = segsAll.length;
  if (n < 2) return const [];
  final bxs = List<double>.filled(n, 0);
  final bys = List<double>.filled(n, 0);
  final bxe = List<double>.filled(n, 0);
  final bye = List<double>.filled(n, 0);
  var minX = double.infinity, maxX = double.negativeInfinity;
  var minY = double.infinity, maxY = double.negativeInfinity;
  for (var i = 0; i < n; i++) {
    final a = segsAll[i][0], b = segsAll[i][1];
    final x0 = a.x < b.x ? a.x : b.x;
    final x1 = a.x < b.x ? b.x : a.x;
    final y0 = a.y < b.y ? a.y : b.y;
    final y1 = a.y < b.y ? b.y : a.y;
    bxs[i] = x0;
    bys[i] = y0;
    bxe[i] = x1;
    bye[i] = y1;
    if (x0 < minX) minX = x0;
    if (x1 > maxX) maxX = x1;
    if (y0 < minY) minY = y0;
    if (y1 > maxY) maxY = y1;
  }
  var cell = near <= 0 ? 1e-4 : near;
  var nx = math.max(1, ((maxX - minX) / cell).ceil());
  var ny = math.max(1, ((maxY - minY) / cell).ceil());
  const maxAxis = 2048;
  if (nx > maxAxis || ny > maxAxis) {
    cell *= math.max(nx, ny) / maxAxis;
    nx = math.max(1, ((maxX - minX) / cell).ceil());
    ny = math.max(1, ((maxY - minY) / cell).ceil());
  }
  final buckets = <int, List<int>>{};
  for (var i = 0; i < n; i++) {
    final cx0 = (((bxs[i] - minX) / cell).floor()).clamp(0, nx - 1);
    final cx1 = (((bxe[i] - minX) / cell).floor()).clamp(0, nx - 1);
    final cy0 = (((bys[i] - minY) / cell).floor()).clamp(0, ny - 1);
    final cy1 = (((bye[i] - minY) / cell).floor()).clamp(0, ny - 1);
    for (var cy = cy0; cy <= cy1; cy++) {
      for (var cx = cx0; cx <= cx1; cx++) {
        final key = cy * nx + cx;
        (buckets[key] ??= <int>[]).add(i);
      }
    }
  }

  final seen = <int>{};
  final pairs = <(int, int)>[];
  void addPair(int i, int j) {
    if (i == j) return;
    final k = i < j ? i * n + j : j * n + i;
    if (seen.add(k)) pairs.add(i < j ? (i, j) : (j, i));
  }

  for (final MapEntry(key: key, value: listA) in buckets.entries) {
    // Внутри одной ячейки — все пары.
    for (var p = 0; p < listA.length; p++) {
      for (var q = p + 1; q < listA.length; q++) {
        addPair(listA[p], listA[q]);
      }
    }
    // 8 соседних ячеек (каждая пара ячеек обрабатывается дважды — дедуп).
    final cx = key % nx;
    final cy = key ~/ nx;
    for (var dx = -1; dx <= 1; dx++) {
      for (var dy = -1; dy <= 1; dy++) {
        if (dx == 0 && dy == 0) continue;
        final xx = cx + dx;
        final yy = cy + dy;
        if (xx < 0 || xx >= nx || yy < 0 || yy >= ny) continue;
        final listB = buckets[yy * nx + xx];
        if (listB == null) continue;
        for (final i in listA) {
          for (final j in listB) {
            addPair(i, j);
          }
        }
      }
    }
  }
  pairs.sort((x, y) => x.$1 != y.$1 ? x.$1 - y.$1 : x.$2 - y.$2);
  return pairs;
}

/// Быстрая проверка малого зазора для гигантских контуров (произведение
/// количеств сегментов велико): точное минимальное расстояние и ближайшие
/// точки — но только по парам сегментов, реально способным быть ближе
/// [near]. null — если min ≥ near или контуры пересекаются (зазор 0).
({double d, Vec2 p1, Vec2 p2})? _heavyGapMetrics(
    List<Vec2> pa, List<Vec2> pb, double near) {
  if (pa.length < 2 || pb.length < 2) return null;
  final segsAll = <List<Vec2>>[];
  for (var i = 0; i + 1 < pa.length; i++) {
    segsAll.add([pa[i], pa[i + 1]]);
  }
  final offA = segsAll.length;
  for (var j = 0; j + 1 < pb.length; j++) {
    segsAll.add([pb[j], pb[j + 1]]);
  }
  final pairs = _nearSegmentPairs(segsAll, near);
  var best = near; // ищем только зазоры строго меньше near
  Vec2 q1 = pa.first, q2 = pb.first;
  for (final (i, j) in pairs) {
    if (i >= offA || j < offA) continue; // разные контуры
    final m = _pairMetrics(
        segsAll[i][0], segsAll[i][1], segsAll[j][0], segsAll[j][1]);
    if (m.d < best) {
      best = m.d;
      q1 = m.p1;
      q2 = m.p2;
      if (best <= 0) break; // пересечение — зазор 0
    }
  }
  if (best <= 0 || best >= near) return null;
  return (d: best, p1: q1, p2: q2);
}

List<Issue> checkSmallGaps(List<CamPath> paths, double minGap,
    {int maxPairs = 300}) {
  final issues = <Issue>[];
  if (minGap <= 0) return issues;

  final lines = <({int idx, List<Vec2> pts})>[];
  for (var i = 0; i < paths.length; i++) {
    if (paths[i].points.length < 2) continue;
    lines.add((idx: i, pts: paths[i].points));
  }
  if (lines.isEmpty) return issues;

  // Bbox контуров — для дешёвого отсечения пар, которые заведомо дальше
  // minGap (иначе на контурах-гигантах проверка «малых зазоров» квадратична
  // и не укладывается в таймаут анализа).
  final bxs = List<double>.filled(lines.length, 0);
  final bys = List<double>.filled(lines.length, 0);
  final bxe = List<double>.filled(lines.length, 0);
  final bye = List<double>.filled(lines.length, 0);
  for (var i = 0; i < lines.length; i++) {
    final pts = lines[i].pts;
    var minX = pts[0].x, maxX = pts[0].x;
    var minY = pts[0].y, maxY = pts[0].y;
    for (var k = 1; k < pts.length; k++) {
      final p = pts[k];
      if (p.x < minX) minX = p.x;
      if (p.x > maxX) maxX = p.x;
      if (p.y < minY) minY = p.y;
      if (p.y > maxY) maxY = p.y;
    }
    bxs[i] = minX;
    bys[i] = minY;
    bxe[i] = maxX;
    bye[i] = maxY;
  }

  // Единый индекс пар сегментов ВСЕХ контуров с bbox-разнесением < minGap
  // (сетка радиус 1 — гарантированное надмножество пар, реально способных
  // быть ближе minGap). Строится ОДИН раз: на контурах-гигантах попарные
  // сетки «контур против контура» давали сотни секунд.
  final offsets = <int>[];
  final segsAll = <List<Vec2>>[];
  final segLine = <int>[];
  for (var li = 0; li < lines.length; li++) {
    final pts = lines[li].pts;
    offsets.add(segsAll.length);
    for (var k = 0; k + 1 < pts.length; k++) {
      segsAll.add([pts[k], pts[k + 1]]);
      segLine.add(li);
    }
  }
  final nearAll = _nearSegmentPairs(segsAll, minGap);
  final cands = <int, List<(int, int)>>{};
  for (final (gi, gj) in nearAll) {
    final a = segLine[gi], b = segLine[gj];
    if (a == b) continue;
    final lo = a < b ? a : b;
    final hi = a < b ? b : a;
    final key = lo * lines.length + hi;
    (cands[key] ??= <(int, int)>[])
        .add((gi - offsets[a], gj - offsets[b]));
  }

  var count = 0;
  for (var a = 0; a < lines.length; a++) {
    for (var b = a + 1; b < lines.length; b++) {
      count++;
      if (count > maxPairs) return issues;
      // Разнесение bbox по осям: если по любой оси >= minGap — расстояние
      // между контурами не может быть меньше minGap.
      var sepX = 0.0;
      var sepY = 0.0;
      if (bxe[a] < bxs[b]) {
        sepX = bxs[b] - bxe[a];
      } else if (bxe[b] < bxs[a]) {
        sepX = bxs[a] - bxe[b];
      }
      if (bye[a] < bys[b]) {
        sepY = bys[b] - bye[a];
      } else if (bye[b] < bys[a]) {
        sepY = bys[a] - bye[b];
      }
      if (sepX >= minGap || sepY >= minGap) continue;
      final list = cands[a * lines.length + b];
      if (list == null || list.isEmpty) continue;
      final pa = lines[a].pts;
      final pb = lines[b].pts;
      var best = minGap; // ищем только зазоры строго меньше minGap
      Vec2 q1 = pa.first, q2 = pb.first;
      for (final (il, jl) in list) {
        final m = _pairMetrics(
            pa[il], pa[il + 1], pb[jl], pb[jl + 1]);
        if (m.d < best) {
          best = m.d;
          q1 = m.p1;
          q2 = m.p2;
          if (best <= 0) break; // пересечение — зазор 0
        }
      }
      if (best <= 0 || best >= minGap) continue;
      final markers = [_round3(q1), _round3(q2)];
      issues.add(_issue(
        'small_gap',
        'warning',
        markers,
        'Зазор ${_fmt3(best)} мм между контурами №${lines[a].idx + 1} и '
            '№${lines[b].idx + 1} меньше минимального ${_fmt2(minGap)} мм.',
        'Увеличить межконтурный зазор (раздвинуть элементы макета).',
        lines[a].idx,
      ));
    }
  }
  return issues;
}

/// Минимальное расстояние между двумя ломаными (аналог LineString.distance).
double _linesDistance(List<Vec2> pa, List<Vec2> pb) {
  var best = double.infinity;
  for (var i = 0; i < pa.length - 1; i++) {
    for (var j = 0; j < pb.length - 1; j++) {
      final d = _segDistance(pa[i], pa[i + 1], pb[j], pb[j + 1]);
      if (d < best) best = d;
      if (best == 0) return 0;
    }
  }
  return best;
}

double _segDistance(Vec2 a1, Vec2 a2, Vec2 b1, Vec2 b2) {
  final hit = _segPair(a1, a2, b1, b2);
  if (hit.pts.isNotEmpty) return 0.0;
  final cand = <double>[
    pointSegmentDistance(b1, a1, a2),
    pointSegmentDistance(b2, a1, a2),
    pointSegmentDistance(a1, b1, b2),
    pointSegmentDistance(a2, b1, b2),
  ];
  var best = cand[0];
  for (var k = 1; k < cand.length; k++) {
    if (cand[k] < best) best = cand[k];
  }
  return best;
}

/// Ближайшая пара точек двух ломаных (аналог shapely.ops.nearest_points).
({Vec2 p1, Vec2 p2}) _nearestPoints(List<Vec2> pa, List<Vec2> pb) {
  var best = double.infinity;
  Vec2 q1 = pa.first, q2 = pb.first;
  for (var i = 0; i < pa.length - 1; i++) {
    for (var j = 0; j < pb.length - 1; j++) {
      final hit = _segPair(pa[i], pa[i + 1], pb[j], pb[j + 1]);
      if (hit.pts.isNotEmpty) return (p1: hit.pts.first, p2: hit.pts.first);
      // Кандидаты: конец одного сегмента на другом.
      final bProj = _proj(pa[i], pb[j], pb[j + 1]);
      final d1 = (pa[i] - bProj).length;
      if (d1 < best) {
        best = d1;
        q1 = pa[i];
        q2 = bProj;
      }
      final bProj2 = _proj(pa[i + 1], pb[j], pb[j + 1]);
      final d2 = (pa[i + 1] - bProj2).length;
      if (d2 < best) {
        best = d2;
        q1 = pa[i + 1];
        q2 = bProj2;
      }
      final aProj = _proj(pb[j], pa[i], pa[i + 1]);
      final d3 = (pb[j] - aProj).length;
      if (d3 < best) {
        best = d3;
        q1 = aProj;
        q2 = pb[j];
      }
      final aProj2 = _proj(pb[j + 1], pa[i], pa[i + 1]);
      final d4 = (pb[j + 1] - aProj2).length;
      if (d4 < best) {
        best = d4;
        q1 = aProj2;
        q2 = pb[j + 1];
      }
    }
  }
  return (p1: q1, p2: q2);
}

/// Проекция точки [p] на отрезок [a]-[b].
Vec2 _proj(Vec2 p, Vec2 a, Vec2 b) {
  final ab = b - a;
  final l2 = ab.lengthSquared;
  if (l2 < 1e-18) return a;
  var t = (p - a).dot(ab) / l2;
  if (t < 0) t = 0;
  if (t > 1) t = 1;
  return a + ab * t;
}
