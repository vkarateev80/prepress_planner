// Статистика и тайминги анализа технологичности по шагам — для диагностики
// «Анализ ошибок занял больше 90 с». Запуск из packages/core:
//   dart run tool/stat_analyze.dart "<файл>"
import 'dart:io';

import '../lib/src/parser/parse_file.dart';
import '../lib/src/model/params.dart';
import '../lib/src/model/issue.dart';
import '../lib/src/manufacturability/geometry_checks.dart';

void main(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln('usage: dart run tool/stat_analyze.dart <file>');
    exitCode = 2;
    return;
  }
  final path = args.first;
  if (!File(path).existsSync()) {
    stderr.writeln('not found: $path');
    exitCode = 2;
    return;
  }
  final t = Stopwatch()..start();
  final raw = parseFile(path);
  t.stop();
  print('PARSE ${raw.length} paths / '
      '${raw.fold<int>(0, (a, p) => a + p.points.length)} pts / '
      '${t.elapsedMilliseconds} ms');
  final lens = raw.map((p) => p.points.length).toList()..sort((a, b) => b - a);
  final total = lens.fold<int>(0, (a, b) => a + b);
  print('TOP points per path: ${lens.take(10).join(', ')}');
  print('median=${lens.isEmpty ? 0 : lens[lens.length ~/ 2]} '
      'totalSegs=${(total - raw.length).clamp(0, 1 << 62)}');

  final p = ManufacturingParams();
  void run(String name, List<Issue> Function() f) {
    final w = Stopwatch()..start();
    final issues = f();
    w.stop();
    print('$name: ${issues.length} issues / ${w.elapsedMilliseconds} ms');
  }

  run('open', () => checkOpenPaths(raw));
  run('dust', () => checkDust(raw, p.minLoopArea));
  run('intersect_self+pair', () => checkIntersectionsDuplicates(raw));
  run('sharp', () => checkSharpCorners(raw, p.minRadius));
  run('small_gap', () => checkSmallGaps(raw, p.minGap));
}
