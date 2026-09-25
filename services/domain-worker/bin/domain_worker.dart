#!/usr/bin/env dart
/// domain-worker — серверный исполнитель домена «Препресс-Планер» (ADR-2).
///
/// Запуск (из `services/domain-worker`):
///   dart pub get --offline     # резолвит path-зависимость packages/core
///   dart bin/domain_worker.dart
///   # или: dart run domain_worker  (см. executables в pubspec.yaml)
///
/// Переменные окружения:
///   PP_DOMAIN_PORT        — порт (по умолчанию 8101);
///   PP_DOMAIN_HOST        — адрес (по умолчанию 0.0.0.0);
///   PP_DOMAIN_TOKEN       — Bearer-токен для POST (пусто — без проверки);
///   PP_DOMAIN_MAX_BODY_MB — лимит тела запроса, МБ (по умолчанию 96);
///   PP_DOMAIN_CONCURRENCY — максимум изолятов (0/пусто — по числу ядер);
///   PP_DOMAIN_TIMEOUT     — таймаут задачи, с (по умолчанию 180);
///   PP_DOMAIN_CORS_ORIGINS— список origin через запятую (пусто — без CORS).
library;

import 'dart:io';

import '../lib/domain_worker.dart';

Future<void> main(List<String> args) async {
  if (args.contains('-h') || args.contains('--help')) {
    stdout.writeln(_usage);
    return;
  }

  final portArg = _intArg(args, '--port', '-p');
  final config = ServerConfig(
    port: portArg,
    host: _strArg(args, '--host'),
  );

  final service = await DomainWorkerService.start(config);
  stdout.writeln('[domain-worker] слушает http://${config.host}:${service.port} '
      '(healthcheck: /healthz, расчёт: POST /calculate)');
  stdout.writeln('[domain-worker] изолятов: '
      '${service.executor.limits.maxConcurrent}, таймаут '
      '${service.executor.limits.timeout.inSeconds} с, лимит тела '
      '${(config.maxBodyBytes / 1024 / 1024).round()} МБ, '
      'токен: ${config.token == null ? 'не требуется' : 'требуется'}');

  var stopping = false;
  Future<void> shutdown(ProcessSignal signal) async {
    if (stopping) return;
    stopping = true;
    stdout.writeln('[domain-worker] получен $signal — останавливаемся…');
    await service.stop();
    exit(0);
  }

  ProcessSignal.sigterm.watch().listen(shutdown);
  if (!Platform.isWindows) {
    ProcessSignal.sigint.watch().listen(shutdown);
  }
}

const String _usage = '''
domain-worker — канонический исполнитель домена packages/core (ADR-2).

Использование: dart bin/domain_worker.dart [--port 8101] [--host 0.0.0.0]

Маршруты:
  GET  /healthz    — статус сервиса (healthcheck);
  GET  /status     — статус + метрики пула изолятов;
  POST /calculate  — доменная цепочка parse→heal/analyze→pattern→calc→variants→teo;
  POST /<стадия>   — отдельная стадия: parse|analyze|heal|pattern|calc|variants|teo.

Пример:
  curl -s localhost:8101/calculate -H 'content-type: application/json' \\
       -d '{"params":{"labelW":50,"labelH":30}}' | head -c 400
''';

int? _intArg(List<String> args, String long, String short) {
  for (var i = 0; i < args.length; i++) {
    final a = args[i];
    if (a == long || a == short) {
      if (i + 1 >= args.length) return null;
      return int.tryParse(args[i + 1]);
    }
    if (a.startsWith('$long=')) return int.tryParse(a.substring(long.length + 1));
  }
  return null;
}

String? _strArg(List<String> args, String long) {
  for (var i = 0; i < args.length; i++) {
    final a = args[i];
    if (a == long && i + 1 < args.length) return args[i + 1];
    if (a.startsWith('$long=')) return a.substring(long.length + 1);
  }
  return null;
}
