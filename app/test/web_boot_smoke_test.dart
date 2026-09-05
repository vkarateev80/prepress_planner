// Смоук: приложение стартует на WEB-платформе (запуск: flutter test
// --platform chrome). На VM этот тест пропускается (там другие код-пути).
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:prepress_planner/main.dart' as app;
import 'package:prepress_planner/src/screens/home_shell.dart';

void main() {
  if (!kIsWeb) {
    test('web-смоук только на web-платформе', () {});
    return;
  }

  testWidgets('web: приложение собирает HomeShell без падений', (tester) async {
    await tester.pumpWidget(const app.PrepressPlannerApp());
    // Даём инициализации лицензии (localStorage/machine_id) завершиться.
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(HomeShell), findsOneWidget,
        reason: 'приложение должно отрисовать HomeShell');
    expect(tester.takeException(), isNull, reason: 'не должно быть исключений');
  });
}
