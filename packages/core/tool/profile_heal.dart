// Диагностика производительности: разбор + лечение одного файла по шагам
// с замером времени. Запуск из packages/core:
//   dart run tool/profile_heal.dart "C:\путь\файл.pdf"
// Печатает тайминги этапов; код возврата 0 = всё завершилось до таймаута
// вызова (сам таймаут НЕ ставит — это диагностика, лечится подолгу).
import 'dart:io';

import '../lib/prepress_core.dart';

void main(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln('usage: dart run tool/profile_heal.dart <file>');
    exitCode = 2;
    return;
  }
  final path = args.first;
  final f = File(path);
  if (!f.existsSync()) {
    stderr.writeln('file not found: $path');
    exitCode = 2;
    return;
  }

  Stopwatch sw() => Stopwatch()..start();

  // 1. Разбор.
  final tParse = sw();
  final raw = parseFile(path);
  tParse.stop();
  final points = raw.fold<int>(0, (a, p) => a + p.points.length);
  print('PARSE: ${raw.length} paths, $points points, '
      '${tParse.elapsedMilliseconds} ms');
  stdout.flush();

  if (raw.isEmpty) {
    print('nothing parsed; skip heal');
    return;
  }

  // 2. Анализ технологичности (что было до лечения в UI).
  final tAnalyze = sw();
  final report = analyzeManufacturability(raw, ManufacturingParams());
  tAnalyze.stop();
  print('ANALYZE: ${report.issues.length} issues, '
      '${tAnalyze.elapsedMilliseconds} ms');
  stdout.flush();

  // 3. Лечение геометрии.
  final tHeal = sw();
  final healed = healGeometry(raw, ManufacturingParams());
  tHeal.stop();
  final closed =
      healed.where((p) => p.isClosed).length;
  print('HEAL: ${healed.length} paths ($closed closed), '
      '${tHeal.elapsedMilliseconds} ms');
  stdout.flush();

  // 4. Контрольный анализ после лечения.
  final tAnalyze2 = sw();
  final report2 = analyzeManufacturability(healed, ManufacturingParams());
  tAnalyze2.stop();
  print('ANALYZE_HEALED: ${report2.issues.length} issues, '
      '${tAnalyze2.elapsedMilliseconds} ms');
}
