// Тесты ConverterApi против локального HTTP-сервера (без внешних пакетов).
// Только test() без testWidgets — flutter_test не подменяет HttpClient.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:prepress_planner/src/converter/converter_api.dart';
import 'package:prepress_planner/src/converter/converter_server.dart';

/// Локальный фейковый сервис конвертации (контракт services/converter).
class _FakeConverterServer {
  HttpServer? _server;
  String contentType = '';
  Uint8List? uploaded;
  int _pollCalls = 0;

  /// Сколько раз GET /convert/{id} отвечает running перед done.
  int runningRounds = 1;
  bool rejectUpload = false;
  String rejectDetail = '';
  bool jobError = false;
  String jobErrorMessage = '';
  bool neverDone = false;

  String get baseUrl => 'http://127.0.0.1:${_server!.port}';
  int get pollCalls => _pollCalls;

  Future<void> start() async {
    _server = await HttpServer.bind('127.0.0.1', 0);
    _server!.listen((req) async {
      try {
        await _handle(req);
      } catch (_) {
        try {
          req.response.statusCode = 500;
          await req.response.close();
        } catch (_) {}
      }
    });
  }

  Future<void> stop() async => _server?.close(force: true);

  Future<void> _handle(HttpRequest req) async {
    final path = req.uri.path;
    if (req.method == 'POST' && path == '/convert') {
      contentType = req.headers.contentType?.toString() ?? '';
      final builder = BytesBuilder(copy: false);
      await for (final chunk in req) {
        builder.add(chunk);
      }
      uploaded = builder.takeBytes();
      if (rejectUpload) {
        req.response.statusCode = 400;
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode({'detail': rejectDetail}));
      } else {
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode({'job_id': 'job-1'}));
      }
      await req.response.close();
      return;
    }
    if (req.method == 'GET' && path == '/convert/job-1') {
      _pollCalls++;
      Map<String, dynamic> body;
      if (jobError) {
        body = {'status': 'error', 'error': jobErrorMessage};
      } else if (neverDone || _pollCalls <= runningRounds) {
        body = {'status': 'running', 'result_url': null, 'error': null};
      } else {
        body = {
          'status': 'done',
          'result_url': '/data/out/job-1/result.svg',
          'error': null
        };
      }
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode(body));
      await req.response.close();
      return;
    }
    if (req.method == 'GET' && path == '/data/out/job-1/result.svg') {
      req.response.headers.contentType =
          ContentType('image', 'svg+xml', charset: 'utf-8');
      req.response.add(utf8.encode('<svg>результат</svg>'));
      await req.response.close();
      return;
    }
    req.response.statusCode = 404;
    await req.response.close();
  }
}

Future<File> _aiFile(Directory dir, [String name = 'label.ai']) async {
  final f = File('${dir.path}/$name');
  await f.writeAsBytes(utf8.encode('FAKE-AI-CONTENT'));
  return f;
}

void main() {
  late Directory dir;

  setUpAll(() async {
    dir = await Directory.systemTemp.createTemp('pp_api_test');
  });

  tearDownAll(() async {
    await dir.delete(recursive: true);
  });

  test('устаревший IP 193.233.193.12 удалён из дефолтов (ADR-6)', () {
    // ADR-6: зашитый IP старого VPS удалён из клиентской логики.
    // На VM без env действует локальный сервер разработки (8120),
    // на web дефолт пуст → относительные URL того же origin (`/convert`).
    expect(ConverterApi.defaultBaseUrl(), isNot(contains('193.233.193.12')));
    expect(ConverterServer.defaultBaseUrl(), isNot(contains('193.233.193.12')));
    final api = ConverterApi(baseUrl: '');
    expect(api.baseUrl, isEmpty);
    expect(ConverterServer.isLocal(''), isFalse);
  });

  test('неподдерживаемый формат отклоняется без обращения к серверу', () async {
    final f = await _aiFile(dir, 'bad.txt');
    final api = ConverterApi(baseUrl: 'http://127.0.0.1:1');
    await expectLater(
      api.convertToSvg(
          fileName: f.path.split(RegExp(r'[\\/]')).last,
          bytes: await f.readAsBytes()),
      throwsA(isA<ConverterException>().having(
          (e) => e.message, 'message', contains('не конвертируется'))),
    );
  });

  test('успех: multipart-загрузка, опрос джобы, скачивание SVG', () async {
    final server = _FakeConverterServer()..runningRounds = 1;
    await server.start();
    addTearDown(server.stop);
    final f = await _aiFile(dir);
    final api = ConverterApi(
        baseUrl: server.baseUrl,
        pollInterval: const Duration(milliseconds: 5),
        timeout: const Duration(seconds: 5));
    final svg = await api.convertToSvg(
        fileName: f.path.split(RegExp(r'[\\/]')).last,
        bytes: await f.readAsBytes());

    // Результат — байты SVG с сервера.
    expect(utf8.decode(svg), '<svg>результат</svg>');
    // Multipart содержит файл и target=svg.
    final body = utf8.decode(server.uploaded!);
    expect(server.contentType, startsWith('multipart/form-data; boundary='));
    expect(body, contains('name="file"'));
    expect(body, contains('filename="import.ai"'));
    expect(body, contains('FAKE-AI-CONTENT'));
    expect(body, contains('name="target"'));
    expect(body, contains('svg'));
    // Джоба опрашивалась: running, затем done.
    expect(server.pollCalls, greaterThanOrEqualTo(2));
  });

  test('сервер отклоняет файл (400) — понятное сообщение', () async {
    final server = _FakeConverterServer()
      ..rejectUpload = true
      ..rejectDetail = 'Формат .txt не поддерживается: допустимы .ai, .cdr, .eps';
    await server.start();
    addTearDown(server.stop);
    final f = await _aiFile(dir);
    final api = ConverterApi(baseUrl: server.baseUrl);
    await expectLater(
      api.convertToSvg(
          fileName: f.path.split(RegExp(r'[\\/]')).last,
          bytes: await f.readAsBytes()),
      throwsA(isA<ConverterException>().having((e) => e.message, 'message',
          contains('не поддерживается'))),
    );
  });

  test('ошибка джобы на сервере — сообщение об ошибке конвертации', () async {
    final server = _FakeConverterServer()
      ..jobError = true
      ..jobErrorMessage = 'Не удалось разобрать файл: повреждённый AI';
    await server.start();
    addTearDown(server.stop);
    final f = await _aiFile(dir);
    final api = ConverterApi(baseUrl: server.baseUrl);
    await expectLater(
      api.convertToSvg(
          fileName: f.path.split(RegExp(r'[\\/]')).last,
          bytes: await f.readAsBytes()),
      throwsA(isA<ConverterException>().having((e) => e.message, 'message',
          contains('Не удалось разобрать файл'))),
    );
  });

  test('джоба не завершается — таймаут', () async {
    final server = _FakeConverterServer()..neverDone = true;
    await server.start();
    addTearDown(server.stop);
    final f = await _aiFile(dir);
    final api = ConverterApi(
        baseUrl: server.baseUrl,
        pollInterval: const Duration(milliseconds: 5),
        timeout: const Duration(milliseconds: 150));
    await expectLater(
      api.convertToSvg(
          fileName: f.path.split(RegExp(r'[\\/]')).last,
          bytes: await f.readAsBytes()),
      throwsA(isA<ConverterException>()
          .having((e) => e.message, 'message', contains('не завершилась'))),
    );
  });
}
