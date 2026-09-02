import 'vec2.dart';

/// Проблема геометрии, найденная при анализе технологичности.
class Issue {
  final String kind; // 'open'|'intersection'|'duplicate'|'dust'|'sharp_corner'|'small_gap'
  final String severity; // 'error'|'warning'|'suggestion'
  final List<Vec2> points; // маркеры на холсте
  final String message; // русский текст
  final String suggestion; // русская рекомендация
  final bool fixable;
  final int index;

  const Issue({
    required this.kind,
    required this.severity,
    required this.points,
    required this.message,
    required this.suggestion,
    required this.fixable,
    required this.index,
  });

  @override
  String toString() => '[Issue $severity/$kind #$index] $message';
}
