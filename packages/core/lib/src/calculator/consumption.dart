/// Свод расхода: полотно (MaterialResult) vs чистая площадь формы (LabelShape).
///
///   usedArea   = calc.count * shape.area;
///   areaMm2    = calc.areaMm2                  (полотно);
///   wasteMm2   = areaMm2 - usedArea;
///   wastePct   = waste / area * 100;
///   perLabelMm2 = areaMm2 / calc.count;
///   webMin     = calc.webMin;
library;

import 'material.dart';
import 'shape.dart';

/// Свод расхода материала по фактической форме этикетки.
class Consumption {
  final double areaMm2; // полотно, мм²
  final double areaM2; // полотно, м²
  final double usedAreaMm2; // чистая площадь всех этикеток, мм²
  final double wasteMm2; // отходы, мм²
  final double wastePct; // отходы, %
  final double perLabelMm2; // полотно на этикетку, мм²/шт
  final double webMin; // минимальная ширина полотна, мм

  const Consumption({
    required this.areaMm2,
    required this.areaM2,
    required this.usedAreaMm2,
    required this.wasteMm2,
    required this.wastePct,
    required this.perLabelMm2,
    required this.webMin,
  });
}

Consumption computeConsumption(MaterialResult calc, LabelShape shape) {
  final usedArea = calc.count * shape.area;
  final waste = calc.areaMm2 - usedArea;
  final wastePct = calc.areaMm2 > 0 ? waste / calc.areaMm2 * 100.0 : 0.0;
  final perLabelMm2 = calc.count > 0 ? calc.areaMm2 / calc.count : 0.0;
  return Consumption(
    areaMm2: calc.areaMm2,
    areaM2: calc.areaM2,
    usedAreaMm2: usedArea,
    wasteMm2: waste,
    wastePct: wastePct,
    perLabelMm2: perLabelMm2,
    webMin: calc.webMin,
  );
}
