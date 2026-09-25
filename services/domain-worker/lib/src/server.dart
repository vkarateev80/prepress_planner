/// HTTP-сервер domain-worker (порт 8101 внутри сети compose, ADR-2/ADR-6).
///
/// Только `dart:io`: `HttpServer`, изоляты для тяжёлых стадий, никаких
/// pub-пакетов. Наружу порт не публикуется — вызовы идут сервер-к-серверу
/// от `api` (`DOMAIN_WORKER_URL`).
///
/// Маршруты:
///   GET  /healthz   — статус (healthcheck compose; N-2);
///   GET  /          — карта сервиса (маршруты, версия, схема);
///   GET  /status    — статус + метрики пула изолятов;
///   POST /calculate — доменная цепочка (синонимы: /calculation, /run, /v1/calculate);
///   POST /<стадия>  — parse | analyze | heal | pattern | calc | variants | teo.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'errors.dart';
import 'isolate_executor.dart';
import 'pipeline.dart';
import 'request.dart';
import 'state.dart';

/// Конфигурация сервиса (значения по умолчанию совпадают с compose).
class ServerConfig {
  /// Порт (внутри контейнера — 8101).
  final int port;

  /// Адрес прослушивания (0.0.0.0 — доступен другим контейнерам сети).
  final String host;

  /// Необязательный Bearer-токен (`PP_DOMAIN_TOKEN`): пусто — без проверки
  /// (dev/внутренняя сеть), задан — обязателен для POST-маршрутов.
  final String? token;

  /// Максимальный размер тела запроса (base64 макета + состояние), байты.
  final int maxBodyBytes;

  /// Максимум одновременно работающих изолятов.
  final int maxConcurrent;

  /// Таймаут одной задачи расчёта.
  final Duration taskTimeout;

  /// Разрешённые origin для CORS (пусто — заголовки не отдаются).
  final List<String> corsOrigins;

  ServerConfig({
    int? port,
    String? host,
    String? token,
    int? maxBodyBytes,
    int? maxConcurrent,
    Duration? taskTimeout,
    List<String>? corsOrigins,
  })  : port = port ?? _envInt('PP_DOMAIN_PORT', 8101),
        host = host ?? Platform.environment['PP_DOMAIN_HOST'] ?? '0.0.0.0',
        token = token ?? _envStr('PP_DOMAIN_TOKEN'),
        maxBodyBytes = maxBodyBytes ??
            _envInt('PP_DOMAIN_MAX_BODY_MB', 96) * 1024 * 1024,
        maxConcurrent =
            maxConcurrent ?? _envInt('PP_DOMAIN_CONCURRENCY', 0),
        taskTimeout = taskTimeout ??
            Duration(
                seconds: _envInt('PP_DOMAIN_TIMEOUT', 180)),
        corsOrigins = corsOrigins ??
            (_envStr('PP_DOMAIN_CORS_ORIGINS') ?? '')
                .split(',')
                .map((s) => s.trim())
                .where((s) => s.isNotEmpty)
                .toList();

  static int _envInt(String name, int fallback) {
    final raw = Platform.environment[name];
    if (raw == null || raw.isEmpty) return fallback;
    return int.tryParse(raw) ?? fallback;
  }

  static String? _envStr(String name) {
    final raw = Platform.environment[name];
    return (raw == null || raw.isEmpty) ? null : raw;
  }

  @override
  String toString() => 'ServerConfig(host: $host, port: $port, '
      'maxBodyBytes: $maxBodyBytes, maxConcurrent: $maxConcurrent или ядра, '
      'token: ${token == null ? 'нет' : 'задан'})';
}

/// Запущенный сервис (для тестов и graceful shutdown).
class DomainWorkerService {
  final HttpServer server;
  final IsolateExecutor executor;
  final ServerConfig config;
  final DateTime startedAt = DateTime.now();
  int requests = 0;
  int errors = 0;

  DomainWorkerService._(this.server, this.executor, this.config);

  int get port => server.port;

  /// Запустить сервис: поднять HTTP-сервер и настроить обработку.
  static Future<DomainWorkerService> start(ServerConfig config) async {
    final executor = IsolateExecutor(
      limits: ExecutorLimits(
        maxConcurrent:
            config.maxConcurrent > 0 ? config.maxConcurrent : null,
        timeout: config.taskTimeout,
      ),
    );
    final server = await HttpServer.bind(config.host, config.port);
    server.autoCompress = false;
    final service = DomainWorkerService._(server, executor, config);
    server.listen(
      service._handle,
      onError: (Object e) {
        stderr.writeln('[domain-worker] ошибка сервера: $e');
      },
      cancelOnError: false,
    );
    return service;
  }

  /// Остановить сервис (SIGTERM/SIGINT): новые задачи не принимаются,
  /// текущие соединения закрываются.
  Future<void> stop() async {
    executor.close();
    await server.close(force: true);
  }

  Future<void> _handle(HttpRequest request) async {
    final sw = Stopwatch()..start();
    requests++;
    try {
      await _route(request);
    } on WorkerError catch (e) {
      errors++;
      await _sendError(request, e);
    } on TimeoutException catch (e) {
      errors++;
      await _sendError(
          request,
          WorkerError.timeout(
              'Превышен таймаут обработки запроса: ${e.message ?? 'нет ответа'}')
      );
    } catch (e, st) {
      errors++;
      stderr.writeln('[domain-worker] необработанная ошибка: $e\n$st');
      await _sendError(
          request,
          WorkerError.internal('Внутренняя ошибка сервиса: $e'));
    } finally {
      if (!request.response.headers.chunkedTransferEncoding) {
        try {
          await request.response.close();
        } catch (_) {/* соединение уже закрыто клиентом */}
      }
      stdout.writeln(jsonEncode({
        'ts': DateTime.now().toUtc().toIso8601String(),
        'method': request.method,
        'path': request.uri.path,
        'ms': sw.elapsedMilliseconds,
      }));
    }
  }

  Future<void> _route(HttpRequest request) async {
    final path = _normalizePath(request.uri.path);
    final method = request.method.toUpperCase();

    if (method == 'OPTIONS') {
      request.response.statusCode = HttpStatus.noContent;
      _applyCors(request);
      await request.response.close();
      return;
    }

    if (path == '/healthz' && (method == 'GET' || method == 'HEAD')) {
      await _sendJson(request, HttpStatus.ok, healthPayload());
      return;
    }

    if (path == '/status' && method == 'GET') {
      await _sendJson(request, HttpStatus.ok, {
        ...healthPayload(),
        'requests': requests,
        'errors': errors,
        'uptimeSeconds': DateTime.now().difference(startedAt).inSeconds,
        'executor': {
          'active': executor.active,
          'queued': executor.queued,
          'maxConcurrent': executor.limits.maxConcurrent,
          'timeoutSeconds': executor.limits.timeout.inSeconds,
        },
      });
      return;
    }

    if (path == '/' && (method == 'GET' || method == 'HEAD')) {
      await _sendJson(request, HttpStatus.ok, _serviceMap());
      return;
    }

    if (method != 'POST') {
      throw WorkerError(
        'method_not_allowed',
        'Метод $method не поддерживается: расчёт выполняется POST-запросом '
        'на /calculate (или /v1/calculate).',
        httpStatus: 405,
      );
    }

    _checkAuth(request);

    final stagePath = _stageFromPath(path);
    if (stagePath == null) {
      throw WorkerError(
        'not_found',
        'Маршрут $path не найден. Доступны: /healthz, /status, /calculate, '
        '/${kStageOrder.join(', /')}.',
        httpStatus: 404,
      );
    }

    final body = await _readBody(request);
    final payload = parseRequestBody(body);
    if (stagePath != 'calculate') {
      // Стадию можно указать и в пути, и в теле; путь имеет приоритет.
      payload['stages'] = [stagePath];
    }
    final result = await executor.run(payload);
    await _sendJson(request, HttpStatus.ok, result);
  }

  /// Ответ `/healthz` (healthcheck compose; секретов не содержит).
  Map<String, dynamic> healthPayload() => {
        'status': 'ok',
        'service': 'domain-worker',
        'version': kWorkerVersion,
        'schemaVersion': kProjectStateSchemaVersion,
        'core': 'packages/core (path-зависимость, чистый Dart)',
        'isolates': true,
        'availableStages': kStageOrder,
        'uptimeSeconds': DateTime.now().difference(startedAt).inSeconds,
      };

  Map<String, dynamic> _serviceMap() => {
        'service': 'domain-worker',
        'version': kWorkerVersion,
        'description': 'Канонический исполнитель packages/core (ADR-2): '
            'parse/analyze/heal/pattern/calc/variants/teo',
        'schema': 'project_state.json v2',
        'endpoints': [
          'GET /healthz',
          'GET /status',
          'POST /calculate (синонимы: /calculation, /run, /v1/calculate)',
          for (final s in kStageOrder) 'POST /$s',
        ],
        'stages': kStageOrder,
        'reference': kReference,
      };

  // ============================================================
  // Тело запроса, ответ, CORS
  // ============================================================

  Future<String> _readBody(HttpRequest request) async {
    final max = config.maxBodyBytes;
    final declared = request.contentLength;
    if (declared > max) {
      throw WorkerError.tooLarge(
          'Тело запроса $declared байт превышает лимит $max байт.');
    }
    final builder = BytesBuilder(copy: false);
    var size = 0;
    await for (final chunk in request) {
      size += chunk.length;
      if (size > max) {
        throw WorkerError.tooLarge(
            'Тело запроса превышает лимит $max байт '
            '(поднимите PP_DOMAIN_MAX_BODY_MB).');
      }
      builder.add(chunk);
    }
    try {
      return utf8.decode(builder.takeBytes());
    } on FormatException {
      throw WorkerError.badRequest(
          'Тело запроса не является корректным UTF-8 (JSON ожидается в UTF-8).');
    }
  }

  Future<void> _sendJson(
      HttpRequest request, int status, Map<String, dynamic> payload) async {
    final response = request.response;
    response.statusCode = status;
    response.headers.contentType =
        ContentType('application', 'json', charset: 'utf-8');
    response.headers.set('Cache-Control', 'no-store');
    _applyCors(request);
    final bytes = utf8.encode(jsonEncode(payload));
    response.headers.contentLength = bytes.length;
    response.add(bytes);
    await response.close();
  }

  Future<void> _sendError(HttpRequest request, WorkerError error) async {
    try {
      await _sendJson(request, error.httpStatus, error.toJson());
    } catch (_) {
      // Ответ уже отправлен (например, ошибка чтения тела после ответа).
      try {
        await request.response.close();
      } catch (_) {}
    }
  }

  void _checkAuth(HttpRequest request) {
    final token = config.token;
    if (token == null) return;
    final header = request.headers.value(HttpHeaders.authorizationHeader);
    if (header == null || !header.startsWith('Bearer ')) {
      throw WorkerError(
        'unauthorized',
        'Требуется заголовок Authorization: Bearer <PP_DOMAIN_TOKEN>.',
        httpStatus: 401,
      );
    }
    if (header.substring('Bearer '.length).trim() != token) {
      throw WorkerError('forbidden', 'Неверный токен доступа.',
          httpStatus: 403);
    }
  }

  void _applyCors(HttpRequest request) {
    if (config.corsOrigins.isEmpty) return;
    final origin = request.headers.value('origin');
    if (origin == null) return;
    if (config.corsOrigins.contains('*') ||
        config.corsOrigins.contains(origin)) {
      request.response.headers.set('Access-Control-Allow-Origin', origin);
      request.response.headers
          .set('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
      request.response.headers.set(
          'Access-Control-Allow-Headers', 'Content-Type, Authorization');
      request.response.headers.set('Vary', 'Origin');
    }
  }

  static String _normalizePath(String raw) {
    var path = raw.trim();
    if (path.isEmpty) return '/';
    while (path.length > 1 && path.endsWith('/')) {
      path = path.substring(0, path.length - 1);
    }
    // nginx/edge может срезать префикс /api; поддерживаем оба варианта.
    for (final prefix in const ['/api/v1', '/api', '/v1']) {
      if (path == prefix) return '/';
      if (path.startsWith('$prefix/')) return path.substring(prefix.length);
    }
    return path;
  }

  static String? _stageFromPath(String path) {
    const aliases = {
      '/calculate': 'calculate',
      '/calculation': 'calculate',
      '/run': 'calculate',
      '/pipeline': 'calculate',
    };
    if (aliases.containsKey(path)) return aliases[path];
    final name = path.startsWith('/') ? path.substring(1) : path;
    if (name == 'all' || name == 'full') return 'calculate';
    if (kStageOrder.contains(name)) return name;
    return null;
  }
}
