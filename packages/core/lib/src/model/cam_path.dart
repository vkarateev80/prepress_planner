import 'vec2.dart';

/// Полилиния векторной геометрии (единица домена).
/// Координаты в мм; кривые уже дискретизированы; ось Y вверх.
class CamPath {
  final List<Vec2> points;
  final bool isClosed;
  final String layerName;

  const CamPath(this.points, {this.isClosed = false, this.layerName = ''});

  CamPath copyWith({List<Vec2>? points, bool? isClosed, String? layerName}) =>
      CamPath(points ?? this.points,
          isClosed: isClosed ?? this.isClosed,
          layerName: layerName ?? this.layerName);

  double get lengthMm {
    var l = 0.0;
    for (var i = 1; i < points.length; i++) {
      l += (points[i] - points[i - 1]).length;
    }
    if (isClosed && points.length > 2) {
      l += (points.first - points.last).length;
    }
    return l;
  }

  @override
  String toString() =>
      'CamPath(${points.length}pts, closed=$isClosed, layer=$layerName)';
}
