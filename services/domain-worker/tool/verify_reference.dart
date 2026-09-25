// Проверка эталонных чисел PRD §10.2 и живого HTTP-сервиса.
//
// Запуск (из services/domain-worker):
//   dart tool/verify_reference.dart                    # только домен (быстро)
//   dart tool/verify_reference.dart --http             # + HTTP на свободном порту
//   dart tool/verify_reference.dart --url http://127.0.0.1:8101
//
// Примечание: предупреждения компилятора о null-aware операциях приходят из
// `packages/core` (он не изменяется) — на результат сверки не влияют.
//
// Код выхода 0 — эталон сошёлся 1:1; 1 — расхождение.
library;

import 'dart:convert';
import 'dart:io';

import '../lib/domain_worker.dart';

const Map<String, double> expected = kReference;

Future<int> main(List<String> args) async {
  var failed = 0;
  print('=== 1. Домен (прямой вызов, как у воркера) ===');
  final local =
      runPipeline({'stages': ['calc', 'teo'], 'includeRawPaths': false});
  failed += _check('локально', local.toJson(includeRawPaths: false));

  final url = _urlArg(args);
  if (url != null || args.contains('--http')) {
    DomainWorkerService? service;
    var base = url;
    if (base == null) {
      service = await DomainWorkerService.start(
          ServerConfig(host: '127.0.0.1', port: 0));
      base = 'http://127.0.0.1:${service.port}';
      print('=== 2. HTTP (временный сервис $base) ===');
    } else {
      print('=== 2. HTTP (внешний сервис $base) ===');
    }
    try {
      final health = await _get('$base/healthz');
      print('healthz: ${jsonEncode(health)}');
      final overHttp = await _post('$base/calculate',
          jsonEncode({'stages': ['calc', 'teo'], 'includeRawPaths': false}));
      failed += _check('HTTP', overHttp);
    } finally {
      client.close(force: true);
      await service?.stop();
    }
  }

  print(failed == 0
      ? 'ЭТАЛОН СОШЁЛСЯ 1:1 (26.18 % / 2032.0 мм² / 704.88 ₽)'
      : 'РАСХОЖДЕНИЕ С ЭТАЛОНОМ: проверок провалено — $failed');
  return failed == 0 ? 0 : 1;
}

int _check(String where, Map<String, dynamic> response) {
  final metrics = (response['metrics'] as Map).cast<String, dynamic>();
  final ref = (metrics['reference'] as Map).cast<String, dynamic>();
  final counting = (metrics['counting'] as Map).cast<String, dynamic>();
  final teo = (response['teo'] as Map?)?.cast<String, dynamic>();
  var failed = 0;
  void check(String name, double actual, double want) {
    final ok = (actual - want).abs() <= kReferenceEps;
    if (!ok) failed++;
    print('  ${ok ? 'OK  ' : 'FAIL'} $where/$name: $actual (эталон $want)');
  }

  check('отходы, %', (counting['wastePct'] as num).toDouble(),
      expected['wastePct']!);
  check('мм²/этикетку', (counting['perLabelAreaMm2'] as num).toDouble(),
      expected['perLabelArea']!);
  check('длина, мм', (counting['lengthMm'] as num).toDouble(),
      expected['lengthMm']!);
  check('раппорт, мм', (counting['rapportMm'] as num).toDouble(),
      expected['rapportMm']!);
  check('N (всего этикеток)', (counting['count'] as num).toDouble(),
      5040);
  check('оборотов', (counting['revs'] as num).toDouble(), 112);
  if (teo != null) {
    check('costPer1000, ₽', (teo['costPer1000'] as num).toDouble(),
        expected['costPer1000']!);
    check('totalCost, ₽', (teo['totalCost'] as num).toDouble(),
        expected['totalCost']!);
    check('machineCost, ₽', (teo['machineCost'] as num).toDouble(),
        expected['machineCost']!);
    check('materialCost, ₽', (teo['materialCost'] as num).toDouble(),
        expected['materialCost']!);
  }
  print('  reference.passed = ${ref['passed']} (checked=${ref['checked']})');
  return failed;
}

final HttpClient client = HttpClient();

Future<Map<String, dynamic>> _get(String url) async {
  final request = await client.getUrl(Uri.parse(url));
  final response = await request.close();
  final text = await response.transform(utf8.decoder).join();
  return (jsonDecode(text) as Map).cast<String, dynamic>();
}

Future<Map<String, dynamic>> _post(String url, String body) async {
  final request = await client.postUrl(Uri.parse(url));
  final bytes = utf8.encode(body);
  request.headers.contentType = ContentType('application', 'json');
  request.headers.contentLength = bytes.length;
  request.add(bytes);
  final response = await request.close();
  final text = await response.transform(utf8.decoder).join();
  if (response.statusCode != 200) {
    stderr.writeln('HTTP ${response.statusCode}: $text');
    return <String, dynamic>{};
  }
  return (jsonDecode(text) as Map).cast<String, dynamic>();
}

String? _urlArg(List<String> args) {
  for (var i = 0; i < args.length; i++) {
    if (args[i] == '--url' && i + 1 < args.length) return args[i + 1];
    if (args[i].startsWith('--url=')) return args[i].substring(6);
  }
  return null;
}
