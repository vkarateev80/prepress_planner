# Агент 00 — Общий интерфейсный хребет (shared interfaces)

Единый источник сигнатур для всех агентов домена. Пакет: `packages/core` (чистый Dart, БЕЗ Flutter, только стандартная библиотека). Тесты: `dart test` из `packages/core`. SDK: `.tools\dart-sdk\bin\dart.exe` (абсолютный путь) или `dart` если в PATH.

## Модель (lib/src/model/)

```dart
// lib/src/model/vec2.dart
class Vec2 {
  final double x, y;
  const Vec2(this.x, this.y);
  Vec2 operator +(Vec2 o) => Vec2(x + o.x, y + o.y);
  Vec2 operator -(Vec2 o) => Vec2(x - o.x, y - o.y);
  Vec2 operator *(double s) => Vec2(x * s, y * s);
  double get length;
  String toString() => '(${x.toStringAsFixed(4)}, ${y.toStringAsFixed(4)})';
}

// lib/src/model/cam_path.dart
class CamPath {
  final List<Vec2> points;   // ломаная; кривые уже дискретизированы
  final bool isClosed;
  final String layerName;
  const CamPath(this.points, {this.isClosed = false, this.layerName = ''});
  CamPath copyWith({List<Vec2>? points, bool? isClosed, String? layerName});
}

// lib/src/model/params.dart
class LayoutParams {
  double labelW; double labelH; double gapX; double gapY;
  int zTeeth; double cp; double rapportManual;   // rapportManual>0 → ручной раппорт
  double cylWidth; double webWidth; double undercut; double minGap;
  String mode;            // 'count' | 'length'
  int count; double length;
  LayoutParams({...дефолты: 50, 30, 3, 3, 96, 3.175, 0, 300, 300, 0.48, 3, 'count', 5000, 10000});
}

class ManufacturingParams {
  double tolerance;   // 2.0
  double minLoopArea; // 1.0
  double minRadius;   // 0.2
  double minGap;      // 0.5
}

class Issue {
  final String kind;       // 'open'|'intersection'|'duplicate'|'dust'|'sharp_corner'|'small_gap'
  final String severity;   // 'error'|'warning'|'suggestion'
  final List<Vec2> points; // маркеры на холсте
  final String message;    // русский текст
  final String suggestion; // русская рекомендация
  final bool fixable;
  final int index;
}
```

## Правила

- Только стандартная библиотека Dart (dart:math, dart:collection, dart:io, dart:typed_data, dart:convert). Сторонних pub-зависимостей НЕТ (нет доступа к pub.dev).
- Числа: координаты округлять до 4 знаков; длины/площади в отчётах — по контексту (2–4 знака).
- Ошибки форматов — исключения с русским текстом (классы `ParserException`, `CalcException`).
- Доменные модули не импортируют Flutter и не знают про UI.
- Имена функций/классов — ТОЧНО по контракту (агенты зависят друг от друга).

## Кодировка и стиль

UTF-8, русские сообщения об ошибках и UI-текстах домена. Имя пакета в pubspec: `prepress_core`. SDK: `>=3.0.0 <4.0.0`.
