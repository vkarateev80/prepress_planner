// HTTP-тесты domain-worker: маршруты, коды ответов, изоляты.
//
// Проверяется контракт из System Design §3.1/ADR-2: `/healthz`, POST `/calculate`
// и POST `/<стадия>`, коды ошибок, работа тяжёлых расчётов в изолятах
// (`Isolate.spawn`) без блокировки приёма запросов.
//
// Запуск:  dart test/server_test.dart   (из services/domain-worker)
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../lib/domain_worker.dart';
import '../tool/test_utils.dart';

Future<({int status, Map<String, dynamic> json})> call(
    HttpClient client, String method, String url,
    {Object? body, String? token}) async {
  final request = await client.openUrl(method, Uri.parse(url));
  request.headers.contentType = ContentType('application', 'json');
  if (token != null) {
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
  }
  if (body != null) {
    final bytes = utf8.encode(body is String ? body : jsonEncode(body));
    request.headers.contentLength = bytes.length;
    request.add(bytes);
  }
  final response = await request.close();
  final text = await response.transform(utf8.decoder).join();
  return (
    status: response.statusCode,
    json: text.isEmpty
        ? <String, dynamic>{}
        : (jsonDecode(text) as Map).cast<String, dynamic>(),
  );
}

Future<void> main() async {
  final service = await DomainWorkerService.start(ServerConfig(
    host: '127.0.0.1',
    port: 0,
    taskTimeout: const Duration(seconds: 60),
  ));
  final base = 'http://127.0.0.1:${service.port}';
  final client = HttpClient();
  try {
    // ===== 1. /healthz — контракт healthcheck (N-2) =====
    {
      final h = await call(client, 'GET', '$base/healthz');
      expectEq(h.status, 200, '/healthz: статус 200');
      expectEq(h.json['status'], 'ok', '/healthz: status = ok');
      expectEq(h.json['service'], 'domain-worker', '/healthz: имя сервиса');
      expectEq(h.json['schemaVersion'], 2, '/healthz: schemaVersion = 2');
      expectEq(h.json['isolates'], true, '/healthz: изоляты включены');
      expect(h.json['availableStages'] is List, '/healthz: список стадий');
      ok('GET /healthz');
    }

    // ===== 2. Карта сервиса и /status =====
    {
      final root = await call(client, 'GET', '$base/');
      expectEq(root.status, 200, 'GET /: статус 200');
      expect((root.json['endpoints'] as List).isNotEmpty,
          'GET /: перечень маршрутов');

      final st = await call(client, 'GET', '$base/status');
      expectEq(st.status, 200, 'GET /status: статус 200');
      expect(st.json['executor'] is Map, 'GET /status: метрики пула изолятов');
      expectEq((st.json['executor'] as Map)['maxConcurrent'] is int, true,
          'GET /status: максимум изолятов');
      ok('GET / и GET /status');
    }

    // ===== 3. POST /calculate — эталон PRD §10.2 через HTTP =====
    {
      final r = await call(client, 'POST', '$base/calculate',
          body: {'stages': ['calc', 'teo']});
      expectEq(r.status, 200, 'POST /calculate: статус 200');
      final metrics = (r.json['metrics'] as Map).cast<String, dynamic>();
      final counting = (metrics['counting'] as Map).cast<String, dynamic>();
      expectEq(counting['rows'], 9, 'POST /calculate: рядов 9');
      expectEq(counting['cols'], 5, 'POST /calculate: колонок 5');
      expectNear(counting['wastePct'] as double, 26.18,
          'POST /calculate: отходы 26.18 %', eps: 0.005);
      expectNear(counting['perLabelAreaMm2'] as double, 2032.0,
          'POST /calculate: 2032.0 мм²/этикетку', eps: 0.005);
      final ref = (metrics['reference'] as Map).cast<String, dynamic>();
      expectEq(ref['passed'], true, 'POST /calculate: сверка эталона пройдена');
      expectEq(ref['delta']['costPer1000'], 0.0,
          'POST /calculate: costPer1000 совпал без отклонения (704.88 ₽)');
      final state = (r.json['state'] as Map).cast<String, dynamic>();
      expectEq(state['schemaVersion'], 2,
          'POST /calculate: ответ — project_state.json v2');
      expect(state['calc'] is Map, 'POST /calculate: state.calc присутствует');
      ok('POST /calculate (эталон 26.18 % / 2032.0 мм² / 704.88 ₽)');
    }

    // ===== 4. Алиасы маршрута и отдельные стадии =====
    {
      for (final path in ['/calculation', '/run', '/v1/calculate', '/api/calculate']) {
        final r = await call(client, 'POST', '$base$path',
            body: {'stages': ['calc']});
        expectEq(r.status, 200, 'POST $path: работает как алиас /calculate');
      }
      final heal = await call(client, 'POST', '$base/heal', body: {
        'fileName': 'quadroring.svg',
        'file_base64': base64Encode(
            File('${Directory.current.path}/../../fixtures/quadroring.svg')
                .readAsBytesSync()),
      });
      expectEq(heal.status, 200, 'POST /heal: статус 200');
      expectEq((heal.json['stageResults'] as Map).containsKey('heal'), true,
          'POST /heal: секция heal');
      expectEq((heal.json['stages'] as List).first, 'heal',
          'POST /heal: стадия взята из пути');
      ok('алиасы /calculate и стадия POST /heal');
    }

    // ===== 5. Коды ошибок и русские сообщения =====
    {
      final bad = await call(client, 'POST', '$base/calculate',
          body: {'stages': ['parse']});
      expectEq(bad.status, 400, 'пустой запрос: HTTP 400');
      expectEq((bad.json['error'] as Map)['code'], 'bad_request',
          'пустой запрос: код bad_request');
      expect(((bad.json['error'] as Map)['message'] as String).isNotEmpty,
          'пустой запрос: русское сообщение');

      final broken = await call(client, 'POST', '$base/calculate', body: '{не json');
      expectEq(broken.status, 400, 'битый JSON: HTTP 400');
      expectEq((broken.json['error'] as Map)['code'], 'bad_request',
          'битый JSON: код bad_request');

      final eps = await call(client, 'POST', '$base/calculate', body: {
        'fileName': 'petlya.eps',
        'file_base64': base64Encode(List<int>.filled(32, 0)),
      });
      expectEq(eps.status, 400, 'EPS без конвертации: HTTP 400');
      expectEq((eps.json['error'] as Map)['code'], 'unsupported_format',
          'EPS без конвертации: unsupported_format');

      final noFile = await call(client, 'POST', '$base/calculate', body: {
        'storage_key': 'org/o/project/p/file/f/1/sha/q.dxf',
      });
      expectEq(noFile.status, 400, 'storage_key без байтов: HTTP 400');
      expectEq((noFile.json['error'] as Map)['code'], 'file_not_found',
          'storage_key без байтов: file_not_found');

      final tooBig = await call(client, 'POST', '$base/calculate',
          body: {'stages': ['calc'], 'params': {'labelW': 9999}});
      expectEq(tooBig.status, 422, 'невязкая геометрия: HTTP 422');
      expectEq((tooBig.json['error'] as Map)['code'], 'geometry_error',
          'невязкая геометрия: geometry_error');

      final notFound = await call(client, 'POST', '$base/nope', body: {});
      expectEq(notFound.status, 404, 'неизвестный маршрут: HTTP 404');
      expectEq((notFound.json['error'] as Map)['code'], 'not_found',
          'неизвестный маршрут: not_found');

      final wrongMethod = await call(client, 'GET', '$base/calculate');
      expectEq(wrongMethod.status, 405, 'GET /calculate: HTTP 405');
      ok('коды ошибок (400/404/405/422) и русские сообщения');
    }

    // ===== 6. Токен доступа (PP_DOMAIN_TOKEN) =====
    {
      final secured = await DomainWorkerService.start(ServerConfig(
        host: '127.0.0.1',
        port: 0,
        token: 'worker-secret',
        taskTimeout: const Duration(seconds: 30),
      ));
      final sbase = 'http://127.0.0.1:${secured.port}';
      try {
        final denied = await call(client, 'POST', '$sbase/calculate',
            body: {'stages': ['calc']});
        expectEq(denied.status, 401, 'без токена: HTTP 401');
        final wrong = await call(client, 'POST', '$sbase/calculate',
            body: {'stages': ['calc']}, token: 'wrong-token');
        expectEq(wrong.status, 403, 'неверный токен: HTTP 403');
        final allowed = await call(client, 'POST', '$sbase/calculate',
            body: {'stages': ['calc']}, token: 'worker-secret');
        expectEq(allowed.status, 200, 'верный токен: HTTP 200');
        final health = await call(client, 'GET', '$sbase/healthz');
        expectEq(health.status, 200, '/healthz без токена доступен (N-2)');
        expectEq(health.json.containsKey('token'), false,
            '/healthz: секретов в ответе нет');
      } finally {
        await secured.stop();
      }
      ok('Bearer-токен и открытый /healthz');
    }

    // ===== 7. Изоляты: параллельные расчёты не блокируют сервер =====
    {
      final requests = <Future<({int status, Map<String, dynamic> json})>>[];
      for (var i = 0; i < 4; i++) {
        requests.add(call(client, 'POST', '$base/calculate',
            body: {'stages': ['calc', 'variants', 'teo']}));
      }
      // Пока считаются 4 задачи, healthcheck обязан отвечать сразу.
      final sw = Stopwatch()..start();
      final health = await call(client, 'GET', '$base/healthz');
      sw.stop();
      expectEq(health.status, 200, 'параллельно: /healthz отвечает');
      expect(sw.elapsedMilliseconds < 2000,
          'параллельно: /healthz не блокируется расчётами '
          '(${sw.elapsedMilliseconds} мс)');
      final results = await Future.wait(requests);
      for (final r in results) {
        expectEq(r.status, 200, 'параллельно: каждый расчёт успешен');
        expectEq((r.json['metrics'] as Map)['reference']['passed'], true,
            'параллельно: эталон сходится в каждом запросе');
      }
      ok('4 параллельных расчёта в изолятах + неблокирующий /healthz');
    }
  } finally {
    client.close(force: true);
    await service.stop();
  }

  print('ALL PASS: server_test');
}
