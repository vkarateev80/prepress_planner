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

bool _bboxHit(Vec2 a1, Vec2 a2, Vec2 b1, Vec2 b2) {
  final ax0 = a1.x < a2.x ? a1.x : a2.x;
  final ax1 = a1.x < a2.x ? a2.x : a1.x;
  final ay0 = a1.y < a2.y ? a1.y : a2.y;
  final ay1 = a1.y < a2.y ? a2.y : a1.y;
  final bx0 = b1.x < b2.x ? b1.x : b2.x;
  final bx1 = b1.x < b2.x ? b2.x : b1.x;
  final by0 = b1.y < b2.y ? b1.y : b2.y;
  final by1 = b1.y < b2.y ? b2.y : b1.y;
  return ax0 <= bx1 && bx0 <= ax1 && ay0 <= by1 && by0 <= ay1;
}

/// Проста ли ломаная (аналог Shapely LineString.is_simple): нет пересечений
/// не-смежных сегментов, кроме общей точки замыкания кольца.
bool _isSimple(List<Vec2> pts, bool isClosed) {
  final n = pts.length;
  if (n < 4) return true; // меньше двух сегментов — пересекаться нечему
  for (var k = 0; k < n - 1; k++) {
    final a1 = pts[k], a2 = pts[k + 1];
    if ((a1 - a2).length < 1e-12) continue; // вырожденный сегмент
    for (var m = k + 2; m < n - 1; m++) {
      if (isClosed && k == 0 && m == n - 2) continue; // пара замыкания кольца
      final b1 = pts[m], b2 = pts[m + 1];
      if ((b1 - b2).length < 1e-12) continue;
      if (!_bboxHit(a1, a2, b1, b2)) continue;
      final res = _segPair(a1, a2, b1, b2);
      if (res.pts.isNotEmpty) return false;
    }
  }
  return true;
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

List<Issue> checkIntersectionsDuplicates(List<CamPath> paths) {
  final issues = <Issue>[];
  final polys = <({int idx, List<Vec2> pts})>[];
  for (var i = 0; i < paths.length; i++) {
    if (paths[i].points.length < 2) continue;
    polys.add((idx: i, pts: paths[i].points));
  }

  // 1. Самопересечения внутри одного контура.
  for (final c in polys) {
    final pts = c.pts;
    final closedGeom = (pts.first - pts.last).length < 1e-4;
    // Как в Python: сегменты строятся по точкам как сохранены; флаг
    // геометрической замкнутости влияет только на пропуск пары замыкания.
    if (!_isSimple(pts, closedGeom)) {
      for (var k = 0; k < pts.length - 1; k++) {
        final a1 = pts[k], a2 = pts[k + 1];
        if ((a1 - a2).length < 1e-12) continue;
        for (var m = k + 2; m < pts.length - 1; m++) {
          if (closedGeom && k == 0 && m == pts.length - 2) continue;
          final b1 = pts[m], b2 = pts[m + 1];
          if ((b1 - b2).length < 1e-12) continue;
          if (!_bboxHit(a1, a2, b1, b2)) continue;
          final res = _segPair(a1, a2, b1, b2);
          if (res.pts.isEmpty) continue;
          if (res.overlap > 0.01) {
            issues.add(_issue(
              'duplicate',
              'warning',
              res.pts,
              'Дубликат сегментов в контуре №${c.idx + 1}.',
              'Нормализовать геометрию (лечение).',
              c.idx,
            ));
          } else {
            issues.add(_issue(
              'intersection',
              'warning',
              res.pts,
              'Самопересечение в контуре №${c.idx + 1}.',
              'Нормализовать геометрию (лечение).',
              c.idx,
            ));
          }
        }
      }
    }
  }

  // 2. Пересечения/дубликаты между разными контурами.
  for (var a = 0; a < polys.length; a++) {
    for (var b = a + 1; b < polys.length; b++) {
      final pa = polys[a].pts;
      final pb = polys[b].pts;
      final hitPts = <Vec2>[];
      var totalOverlap = 0.0;
      var hit = false;
      for (var i = 0; i < pa.length - 1; i++) {
        final a1 = pa[i], a2 = pa[i + 1];
        if ((a1 - a2).length < 1e-12) continue;
        for (var j = 0; j < pb.length - 1; j++) {
          final b1 = pb[j], b2 = pb[j + 1];
          if ((b1 - b2).length < 1e-12) continue;
          if (!_bboxHit(a1, a2, b1, b2)) continue;
          final res = _segPair(a1, a2, b1, b2);
          if (res.pts.isEmpty) continue;
          hit = true;
          hitPts.addAll(res.pts);
          totalOverlap += res.overlap;
        }
      }
      if (!hit) continue;
      if (totalOverlap > 0.01) {
        issues.add(_issue(
          'duplicate',
          'warning',
          hitPts,
          'Дубликат: контуры №${polys[a].idx + 1} и №${polys[b].idx + 1}.',
          'Нормализовать геометрию (лечение).',
          polys[a].idx,
        ));
      } else {
        issues.add(_issue(
          'intersection',
          'warning',
          hitPts,
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

List<Issue> checkSmallGaps(List<CamPath> paths, double minGap,
    {int maxPairs = 300}) {
  final issues = <Issue>[];
  if (minGap <= 0) return issues;

  final lines = <({int idx, List<Vec2> pts})>[];
  for (var i = 0; i < paths.length; i++) {
    if (paths[i].points.length < 2) continue;
    lines.add((idx: i, pts: paths[i].points));
  }

  var count = 0;
  for (var a = 0; a < lines.length; a++) {
    for (var b = a + 1; b < lines.length; b++) {
      count++;
      if (count > maxPairs) return issues;
      final d = _linesDistance(lines[a].pts, lines[b].pts);
      if (d > 0.0 && d < minGap) {
        final (:p1, :p2) = _nearestPoints(lines[a].pts, lines[b].pts);
        final markers = [_round3(p1), _round3(p2)];
        issues.add(_issue(
          'small_gap',
          'warning',
          markers,
          'Зазор ${_fmt3(d)} мм между контурами №${lines[a].idx + 1} и '
              '№${lines[b].idx + 1} меньше минимального ${_fmt2(minGap)} мм.',
          'Увеличить межконтурный зазор (раздвинуть элементы макета).',
          lines[a].idx,
        ));
      }
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
