/// Генератор сетки Step&Repeat (порт cam_pipeline: CamPipeline.multiply_paths
/// + controller.open_array_generator / autoRowsForRapport).
library;

import '../model/cam_path.dart';
import '../model/vec2.dart';

/// Клонирование мастер-штампа: для каждого [offsets] и каждого пути мастера —
/// копия, сдвинутая на смещение. Координаты округляются до 4 знаков
/// (как round(x, 4) в Python). Слой копий — [layerName].
List<CamPath> multiplyPaths(List<CamPath> master, List<Vec2> offsets,
    {String layerName = 'ARRAY'}) {
  final out = <CamPath>[];
  for (final off in offsets) {
    for (final p in master) {
      final pts = <Vec2>[];
      for (final v in p.points) {
        pts.add((v + off).round4());
      }
      out.add(CamPath(pts,
          isClosed: p.isClosed, layerName: layerName));
    }
  }
  return out;
}

/// Авто-подбор числа рядов под раппорт шестерни (controller.auto_calc_y):
/// rows_max = int(rapport // (labelH + minGap)); меньше 1 → 0.
int autoRowsForRapport(double rapport, double labelH, double minGap) {
  final denom = labelH + minGap;
  if (denom <= 0) return 0;
  final maxRows = (rapport / denom).floor();
  return maxRows < 1 ? 0 : maxRows;
}

/// Генерация сетки массива (controller.on_generate):
/// смещения for c in 0..cols-1, for r in 0..rows-1: (c*stepX, -r*stepY),
/// координаты округляются до 4 знаков; затем multiplyPaths.
List<CamPath> generateArrayGrid(List<CamPath> master,
    {required int cols,
    required int rows,
    required double stepX,
    required double stepY,
    String layerName = 'ARRAY'}) {
  final offsets = <Vec2>[];
  for (var c = 0; c < cols; c++) {
    for (var r = 0; r < rows; r++) {
      offsets.add(Vec2(c * stepX, -r * stepY).round4());
    }
  }
  return multiplyPaths(master, offsets, layerName: layerName);
}
