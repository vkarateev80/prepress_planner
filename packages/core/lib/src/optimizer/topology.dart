/// Топологическая оптимизация (порт cam_material src/optimizer/topology.py):
/// удаление коллинеарных точек (Дуглас–Пекер, preserve topology), округление
/// до 4 знаков. Предотвращает «заикание» станка на прямых участках.
library;

import '../geom/geom_ops.dart';
import '../model/cam_path.dart';
import '../model/vec2.dart';

class TopologicalOptimizer {
  final double simplifyTolerance;

  const TopologicalOptimizer({this.simplifyTolerance = 0.001});

  List<CamPath> optimize(List<CamPath> paths) {
    final out = <CamPath>[];
    for (final path in paths) {
      if (path.points.length < 2) continue;
      final pts = path.points;
      List<Vec2> simplified;
      if (path.isClosed && pts.length >= 3) {
        // Замкнутый контур: упрощение с сохранением замкнутости.
        simplified = simplifyRing(pts, simplifyTolerance);
      } else {
        simplified = _simplifyOpen(pts, simplifyTolerance);
      }
      if (simplified.length < 2) continue;
      out.add(CamPath(_round4(simplified),
          isClosed: path.isClosed, layerName: path.layerName));
    }
    return out;
  }

  /// Дуглас–Пекер для открытой ломаной (концы сохраняются).
  List<Vec2> _simplifyOpen(List<Vec2> pts, double tol) {
    if (pts.length < 3) return List.of(pts);
    final keep = List<bool>.filled(pts.length, false);
    keep[0] = true;
    keep[pts.length - 1] = true;
    final stack = <(int, int)>[(0, pts.length - 1)];
    while (stack.isNotEmpty) {
      final (i0, i1) = stack.removeLast();
      if (i1 <= i0 + 1) continue;
      var maxD = -1.0;
      var idx = -1;
      for (var i = i0 + 1; i < i1; i++) {
        final d = pointSegmentDistance(pts[i], pts[i0], pts[i1]);
        if (d > maxD) {
          maxD = d;
          idx = i;
        }
      }
      if (idx >= 0 && maxD > tol) {
        keep[idx] = true;
        stack.add((i0, idx));
        stack.add((idx, i1));
      }
    }
    final out = <Vec2>[];
    for (var i = 0; i < pts.length; i++) {
      if (keep[i]) out.add(pts[i]);
    }
    return out.length >= 2 ? out : [pts.first, pts.last];
  }

  List<Vec2> _round4(List<Vec2> pts) => pts
      .map((p) => Vec2(
          double.parse(p.x.toStringAsFixed(4)),
          double.parse(p.y.toStringAsFixed(4))))
      .toList();
}
