// Регрессия: «Рассчитать» в LayoutScreen выполняет реальный Isolate.run.
// Раньше VM клал `this` в общий контекст активации с setState-замыканием, и
// отправка падала («object is unsendable»). Теперь тяжёлые вызовы идут через
// топ-левел функции — изолят не видит состояние экрана. Проверяем под
// tester.runAsync (настоящий event loop, реальный изолят).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:prepress_planner/src/projects/project.dart';
import 'package:prepress_planner/src/screens/layout_screen.dart';

void main() {
  testWidgets('layout: расчёт в реальном изоляте даёт эталон 9×5 / 5040',
      (tester) async {
    await tester.runAsync(() async {
      Project? changed;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: LayoutScreen(
            project: Project(name: 'p'),
            onChange: (p) => changed = p,
          ),
        ),
      ));
      await tester.pump();
      expect(find.text('Рассчитать'), findsOneWidget);
      await tester.tap(find.text('Рассчитать'));
      // Ждём завершения реального Isolate.run.
      final deadline = DateTime.now().add(const Duration(seconds: 30));
      while (changed?.calc == null && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      await tester.pump();
      expect(changed?.calc, isNotNull);
      expect(changed!.calc!.rows, 9);
      expect(changed!.calc!.cols, 5);
      expect(changed!.calc!.count, 5040);
    });
  });
}
