// Импорт закрытого формата (.ai): маршрутизация через конвертер в SVG,
// разбор доменом и обновление проекта.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:prepress_core/prepress_core.dart';
import 'package:prepress_planner/src/converter/converter_api.dart';
import 'package:prepress_planner/src/projects/project.dart';
import 'package:prepress_planner/src/screens/geometry_screen.dart';

class _FakeConverter implements Converter {
  bool called = false;
  _FakeConverter();

  @override
  String get baseUrl => 'http://fake:8120';

  @override
  Future<Uint8List> convertToSvg(
      {required String fileName, required Uint8List bytes}) async {
    called = true;
    // Конвертер вернул «SVG»; разбор подменён parseOverride — контент не важен.
    return Uint8List.fromList('<svg/>'.codeUnits);
  }
}

void main() {
  testWidgets('импорт .ai: файл уходит в конвертер, SVG разбирается, '
      'проект получает контуры', (tester) async {
    final dir = Directory.systemTemp.createTempSync('pp_ai_import');
    addTearDown(() => dir.deleteSync(recursive: true));
    final ai = File('${dir.path}/label.ai');
    // Реальный файловый ввод-вывод — только внутри runAsync (fakeAsync
    // не выполняет системные операции).
    await tester.runAsync(() => ai.writeAsBytes(const [1, 2, 3]));

    final converter = _FakeConverter();
    Project? captured;

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: GeometryScreen(
          project: Project(name: 'Тест AI'),
          onChange: (p) => captured = p,
          converter: converter,
          // Детерминированный «разбор+анализ»: изоляты не запускаются
          // под fakeAsync widget-тестов.
          processOverride: (_) async => (
                paths: const [
                  CamPath([
                    Vec2(0, 0),
                    Vec2(10, 0),
                    Vec2(10, 10),
                    Vec2(0, 10),
                  ], isClosed: true),
                ],
                issueList: <Issue>[],
              ),
        ),
      ),
    ));

    await tester.enterText(find.byType(TextField), ai.path);
    await tester.runAsync(() async {
      await tester.tap(find.text('Импорт'));
      await tester.pump();
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (captured == null && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    });
    await tester.pump();

    expect(converter.called, isTrue,
        reason: '.ai обязан уходить через конвертер');
    expect(captured, isNotNull, reason: 'проект должен обновиться');
    expect(captured!.inputFile, ai.path);
    expect(captured!.rawPaths, hasLength(1),
        reason: 'заглушка разбора возвращает один контур');
    expect(find.textContaining('Конвертация успешна'), findsOneWidget);
  });
}
