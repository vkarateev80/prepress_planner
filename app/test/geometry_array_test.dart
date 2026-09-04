// Регрессия «Распознать массив»: определяются мастер-элемент и закон
// (rows×cols, шаги), лечится только мастер, массив размножается по закону на
// слой ARRAY, параметры раскроя заполняются из массива. Реальные изоляты —
// под tester.runAsync.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:prepress_core/prepress_core.dart';
import 'package:prepress_planner/src/projects/project.dart';
import 'package:prepress_planner/src/screens/geometry_screen.dart';

void main() {
  testWidgets('geometry: распознавание даёт мастер, массив и параметры раскроя',
      (tester) async {
    await tester.runAsync(() async {
      // Синтетический массив: квадрат 10×10 (как из SVG-парсера — с повторённой
      // первой вершиной в конце), сетка 3 колонки × 2 ряда, шаг 20×15 мм
      // (зазоры 10 и 5 мм) — как в аг.04.
      const master = CamPath([
        Vec2(0, 0),
        Vec2(10, 0),
        Vec2(10, 10),
        Vec2(0, 10),
        Vec2(0, 0),
      ], isClosed: true);
      final array = generateArrayGrid([master],
          cols: 3, rows: 2, stepX: 20, stepY: 15);

      Project? changed;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: GeometryScreen(
            project: Project(name: 'p', rawPaths: array, healedPaths: array),
            onChange: (p) => changed = p,
          ),
        ),
      ));
      await tester.pump();

      await tester.tap(find.text('Распознать массив'));
      final deadline = DateTime.now().add(const Duration(seconds: 30));
      while ((changed?.pattern?.isArray ?? false) == false &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 40));
        await tester.pump();
      }
      await tester.pump();
      final p = changed;
      expect(p, isNotNull, reason: 'проект должен обновиться');
      expect(p!.pattern?.isArray, isTrue,
          reason: 'массив должен распознаться');
      expect(p.pattern!.rows, 2);
      expect(p.pattern!.cols, 3);
      expect(p.arrayPaths.length, 6,
          reason: 'мастер должен быть размножен по закону 3×2');
      expect(p.arrayPaths.every((c) => c.layerName == 'ARRAY'), isTrue,
          reason: 'копии — отдельный слой ARRAY');
      expect(p.pattern!.masterPaths.every((c) => c.layerName == 'MASTER'),
          isTrue,
          reason: 'мастер-элемент — слой MASTER');
      // Автозаполнение параметров раскроя из массива.
      expect((p.params.labelW - 10).abs() < 0.6, isTrue,
          reason: 'labelW из массива, было ${p.params.labelW}');
      expect((p.params.labelH - 10).abs() < 0.6, isTrue);
      expect((p.params.gapX - 10).abs() < 0.6, isTrue,
          reason: 'gapX = шаг − этикетка');
      expect((p.params.gapY - 5).abs() < 0.6, isTrue,
          reason: 'gapY = шаг − этикетка');
    });
  });
}
