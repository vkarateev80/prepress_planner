// Тесты ConverterServer: поиск venv-python и каталога services/converter
// по структуре репозитория (подъём от каталога приложения вверх).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:prepress_planner/src/converter/converter_server.dart';

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('pp_conv_server_test_');
  });

  tearDown(() async {
    try {
      await root.delete(recursive: true);
    } catch (_) {}
  });

  test('findPythonAbove находит venv, поднимаясь от глубокого каталога', () {
    // Структура репозитория: cam_pipeline/venv + services/converter.
    final py = File('${root.path}/cam_pipeline/venv/Scripts/python.exe')
      ..createSync(recursive: true);
    File('${root.path}/services/converter/converter_app/main.py')
        .createSync(recursive: true);
    // Приложение в app/build/windows/x64/runner/Release — 5 уровней вниз.
    final start = '${root.path}/app/build/windows/x64/runner/Release';

    final found = ConverterServer.findPythonAbove(start);
    expect(found, py.path, reason: 'python должен найтись в корне репозитория');
  });

  test('findPythonAbove возвращает null без структуры репозитория', () {
    File('${root.path}/other/venv/Scripts/python.exe')
        .createSync(recursive: true);
    expect(ConverterServer.findPythonAbove('${root.path}/other'), isNull);
  });

  test('findPythonAbove останавливается на первом найденном репозитории', () {
    // Вложенный «фейковый» репозиторий глубже настоящего — побеждает ближний.
    final py = File('${root.path}/cam_pipeline/venv/Scripts/python.exe')
      ..createSync(recursive: true);
    File('${root.path}/services/converter/converter_app/main.py')
        .createSync(recursive: true);
    final start = '${root.path}/app';
    expect(ConverterServer.findPythonAbove(start), py.path);
  });
}
