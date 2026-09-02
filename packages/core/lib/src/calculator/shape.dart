/// Shape-модель этикетки: чистая площадь формы + эффективность заполнения bbox.
///
/// [LabelShape.w]/[LabelShape.h] — габариты bbox W×H (драйвер сетки раскроя),
/// [LabelShape.area] — чистая площадь формы, мм²,
/// [LabelShape.efficiency] — area / (w * h), 0..1.
library;

import 'dart:math' as math;
import '../model/vec2.dart';
import '../geom/geom_ops.dart';

/// Форма этикетки.
class LabelShape {
  final String kind; // 'rect' | 'roundRect' | 'circle' | 'ellipse' | 'polygon'
  final double w; // bbox ширина, мм (драйвер сетки)
  final double h; // bbox высота, мм (драйвер сетки)
  final double area; // чистая площадь, мм²
  final double efficiency; // area / (w * h)

  const LabelShape({
    required this.kind,
    required this.w,
    required this.h,
    required this.area,
    required this.efficiency,
  });
}

double _efficiency(double area, double w, double h) {
  final box = w * h;
  return box > 0 ? area / box : 0.0;
}

/// Форма из пресета:
///   'rect'      — area = w*h;
///   'roundRect' — area = w*h - (4-pi)*r*r, r = [radius] (ожидается r <= min(w,h)/2);
///   'circle'    — w == h == d: area = pi*(d/2)^2;
///   'ellipse'   — area = pi*(w/2)*(h/2);
///   'polygon'   — без полигона считаем как rect (этикетка прямоугольная);
///   иной вид    — прямоугольная этикетка.
LabelShape shapeFromPreset(String kind, double w, double h,
    {double radius = 0}) {
  final double area;
  switch (kind) {
    case 'roundRect':
      final r = radius > 0 ? radius : 0.0;
      area = w * h - (4.0 - math.pi) * r * r;
      break;
    case 'circle':
    case 'ellipse':
      area = math.pi * (w / 2.0) * (h / 2.0);
      break;
    default: // 'rect', 'polygon', неизвестные виды — прямоугольная этикетка
      area = w * h;
  }
  return LabelShape(
      kind: kind, w: w, h: h, area: area, efficiency: _efficiency(area, w, h));
}

/// Форма по произвольному кольцу (полигону): площадь по шнуркам
/// ([ringAreaAbs]), габариты — по bbox кольца.
LabelShape shapeFromPolygon(List<Vec2> ring) {
  final b = ringBounds(ring);
  final area = ringAreaAbs(ring);
  return LabelShape(
    kind: 'polygon',
    w: b.isEmpty ? 0.0 : b.width,
    h: b.isEmpty ? 0.0 : b.height,
    area: area,
    efficiency: _efficiency(area, b.width, b.height),
  );
}
