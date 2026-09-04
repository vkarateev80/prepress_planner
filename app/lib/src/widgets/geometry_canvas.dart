/// Холст геометрии: полилинии + маркеры ошибок; зум/пан/fit.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:prepress_core/prepress_core.dart';

class GeometryCanvas extends StatefulWidget {
  final List<CamPath> paths;
  final List<Issue> issues;
  const GeometryCanvas(
      {super.key, required this.paths, this.issues = const []});

  @override
  State<GeometryCanvas> createState() => _GeometryCanvasState();
}

class _GeometryCanvasState extends State<GeometryCanvas> {
  double _scale = 1.0;
  Offset _offset = Offset.zero;
  bool _userScaled = false;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      final size = Size(constraints.maxWidth, constraints.maxHeight);
      final bbox = _bounds(widget.paths);
      // Авто-fit при первом появлении (до первого зума пользователем).
      if (!_userScaled && bbox != null && size.width > 0 && size.height > 0) {
        final sx = size.width / (bbox.width > 0 ? bbox.width : 1);
        final sy = size.height / (bbox.height > 0 ? bbox.height : 1);
        _scale = (sx < sy ? sx : sy) * 0.9;
        _scale = _scale.clamp(1e-3, 1e6);
        _offset = Offset(
          (size.width - bbox.width * _scale) / 2 - bbox.minX * _scale,
          (size.height - bbox.height * _scale) / 2 - bbox.minY * _scale,
        );
      }
      return Listener(
        onPointerSignal: (event) {
          if (event is PointerScrollEvent) {
            final factor = event.scrollDelta.dy < 0 ? 1.15 : 1 / 1.15;
            setState(() {
              _scale = (_scale * factor).clamp(1e-3, 1e6);
              _userScaled = true;
            });
          }
        },
        child: GestureDetector(
          onScaleStart: (_) => _userScaled = true,
          onScaleUpdate: (d) {
            setState(() => _offset = _offset + d.focalPointDelta);
          },
          child: ClipRect(
            child: CustomPaint(
              size: size,
              painter: _CanvasPainter(
                  paths: widget.paths,
                  issues: widget.issues,
                  scale: _scale,
                  offset: _offset),
            ),
          ),
        ),
      );
    });
  }

  static BBox? _bounds(List<CamPath> paths) {
    var minX = double.infinity, minY = double.infinity;
    var maxX = double.negativeInfinity, maxY = double.negativeInfinity;
    var any = false;
    for (final p in paths) {
      for (final v in p.points) {
        any = true;
        if (v.x < minX) minX = v.x;
        if (v.y < minY) minY = v.y;
        if (v.x > maxX) maxX = v.x;
        if (v.y > maxY) maxY = v.y;
      }
    }
    return any ? BBox(minX, minY, maxX, maxY) : null;
  }
}

class _CanvasPainter extends CustomPainter {
  final List<CamPath> paths;
  final List<Issue> issues;
  final double scale;
  final Offset offset;

  _CanvasPainter(
      {required this.paths,
      required this.issues,
      required this.scale,
      required this.offset});

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size,
        Paint()..color = const Color(0xFFFAFAFA));
    final border = Paint()
      ..color = const Color(0xFFE0E0E0)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    canvas.drawRect(Offset.zero & size, border);

    Offset toScreen(Vec2 p) =>
        Offset(offset.dx + p.x * scale, offset.dy + p.y * scale);

    // Цвет по «слою» пути: мастер-элемент — бирюзовый, копии массива —
    // индиго, вылеченные контуры — тёмные, исходные — светло-серые.
    for (final p in paths) {
      if (p.points.length < 2) continue;
      final l = p.layerName;
      final pathPaint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = l == 'MASTER' ? 2.2 : 1.5
        ..color = l == 'MASTER'
            ? const Color(0xFF00695C)
            : (l.contains('ARRAY')
                ? const Color(0xFF5C6BC0)
                : (l.startsWith('HEALED_')
                    ? const Color(0xFF37474F)
                    : const Color(0xFF90A4AE)));
      final path = Path();
      final first = toScreen(p.points.first);
      path.moveTo(first.dx, first.dy);
      for (final v in p.points.skip(1)) {
        final s = toScreen(v);
        path.lineTo(s.dx, s.dy);
      }
      if (p.isClosed) path.close();
      canvas.drawPath(path, pathPaint);
    }

    for (final issue in issues) {
      final color = switch (issue.severity) {
        'error' => const Color(0xFFD32F2F),
        'warning' => const Color(0xFFF57C00),
        _ => const Color(0xFFF9A825),
      };
      final fill = Paint()..color = color;
      final halo = Paint()
        ..color = color.withValues(alpha: 0.35)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2;
      for (final v in issue.points) {
        final s = toScreen(v);
        canvas.drawCircle(s, 7, halo);
        canvas.drawCircle(s, 4, fill);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _CanvasPainter old) =>
      old.paths != paths ||
      old.issues != issues ||
      old.scale != scale ||
      old.offset != offset;
}
