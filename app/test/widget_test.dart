// Тесты UI: навигация, форма расчёта, холст, хранилище.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:prepress_core/prepress_core.dart';
import 'package:prepress_planner/src/projects/project.dart';
import 'package:prepress_planner/src/screens/home_shell.dart';
import 'package:prepress_planner/src/widgets/geometry_canvas.dart';
import 'package:prepress_planner/src/widgets/params_form.dart';
import 'package:prepress_planner/src/widgets/variants_table.dart';

void main() {
  testWidgets('home shell: вкладки существуют', (tester) async {
    final dir = Directory.systemTemp.createTempSync('pp_test');
    await tester.pumpWidget(
        MaterialApp(home: HomeShell(store: ProjectStore(dir.path))));
    // Не используем pumpAndSettle: ProjectsScreen делает реальный File IO
    // в initState (список проектов), который не завершается в fakeAsync.
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('Проекты'), findsWidgets);
    expect(find.text('Геометрия'), findsWidgets);
    expect(find.text('Раскрой'), findsWidgets);
    expect(find.text('ТЭО'), findsWidgets);
    expect(find.text('Отчёты'), findsWidgets);
    dir.deleteSync(recursive: true);
  });

  testWidgets('params form: эталон 50x30 -> расчёт по кнопке', (tester) async {
    MaterialResult? result;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ParamsForm(
          initial: LayoutParams(),
          onChanged: (p) {
            result = computeMaterialAuto(p);
          },
        ),
      ),
    ));
    await tester.tap(find.text('Рассчитать'));
    await tester.pump();
    expect(result, isNotNull);
    expect(result!.rows, 9);
    expect(result!.cols, 5);
    expect(result!.count, 5040);
  });

  testWidgets('variants table: отображает варианты и выбор', (tester) async {
    final variants = enumerateVariants(LayoutParams(), limit: 10);
    int? selected;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: VariantsTable(
          variants: variants,
          selectedIndex: 0,
          onSelect: (i) => selected = i,
        ),
      ),
    ));
    expect(find.text('9×5'), findsWidgets);
    expect(find.text('5040'), findsWidgets);
    // Клик по второй строке.
    await tester.tap(find.text('5×9').first);
    await tester.pump();
    expect(selected, isNotNull);
  });

  testWidgets('geometry canvas: рисует квадрат', (tester) async {
    final square = const CamPath([
      Vec2(0, 0),
      Vec2(10, 0),
      Vec2(10, 10),
      Vec2(0, 10)
    ], isClosed: true);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: GeometryCanvas(paths: [square]),
      ),
    ));
    expect(tester.takeException(), isNull);
  });

  test('project store: round-trip project_state v2', () async {
    final dir = await Directory.systemTemp.createTemp('pp_store');
    final store = ProjectStore(dir.path);
    final p = Project(name: 'Эталон')
      ..params = LayoutParams(labelW: 50, labelH: 30)
      ..calc = computeMaterialAuto(LayoutParams())
      ..healedPaths = [
        const CamPath([Vec2(0, 0), Vec2(1, 1)], isClosed: true)
      ];
    await store.save(p);
    final loaded = await store.load('Эталон');
    expect(loaded, isNotNull);
    expect(loaded!.name, 'Эталон');
    expect(loaded.params.labelW, 50);
    expect(loaded.params.labelH, 30);
    expect(loaded.calc!.rows, 9);
    expect(loaded.calc!.cols, 5);
    expect(loaded.healedPaths.length, 1);
    // Версия схемы.
    final raw =
        jsonDecode(await File('${dir.path}/Эталон.json').readAsString())
            as Map<String, dynamic>;
    expect(raw['schemaVersion'], 2);
    await dir.delete(recursive: true);
  });
}
