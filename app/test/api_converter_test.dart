// Тесты ApiConverter (ADR-7): загрузка в services/api + скачание SVG,
// фолбэк на прямой services/converter без сессии. Локальный фейковый сервер.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:prepress_planner/src/converter/api_converter.dart';
import 'package:prepress_planner/src/converter/converter_api.dart';
import 'package:prepress_planner/src/projects/cloud_projects.dart';

/// Фейковый `services/api`: multipart-загрузка с convert → content SVG.
class _FakeApi {
  HttpServer? _server;
  final List<String> log = [];
  final List<String?> authHeaders = [];
  String? uploadBody;
  bool denyUpload = false;

  static const svg = '<svg xmlns="http://www.w3.org/2000/svg"></svg>';

  String get baseUrl => 'http://127.0.0.1:${_server!.port}/api';

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
    log.add('${req.method} $path${req.uri.query.isEmpty ? '' : '?${req.uri.query}'}');
    authHeaders.add(req.headers.value('Authorization'));

    if (req.method == 'POST' && path == '/api/projects/p1/files') {
      final text = await utf8.decoder.bind(req).join();
      uploadBody = text;
      if (denyUpload) {
        req.response.statusCode = 403;
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode({
          'error': {
            'code': 'converter_failed',
            'message': 'Конвертация не удалась: файл повреждён.',
          }
        }));
      } else {
        req.response.statusCode = 201;
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode({
          'converted': true,
          'async': false,
          'converted_file_id': 'c1',
          'parent_file_id': 'f0',
        }));
      }
      await req.response.close();
      return;
    }
    if (req.method == 'GET' && path == '/api/files/c1/content') {
      req.response.statusCode = 200;
      req.response.headers.contentType = ContentType.parse('image/svg+xml');
      req.response.write(svg);
      await req.response.close();
      return;
    }
    req.response.statusCode = 404;
    req.response.headers.contentType = ContentType.json;
    req.response.write(jsonEncode({
      'error': {'code': 'not_found', 'message': 'Не найдено.'}
    }));
    await req.response.close();
  }
}

/// Заглушка прямого конвертера: фиксирует, что фолбэк был вызван.
class _FakeDirectConverter implements Converter {
  bool called = false;
  @override
  String get baseUrl => 'http://direct.test';

  @override
  Future<Uint8List> convertToSvg(
      {required String fileName, required Uint8List bytes}) async {
    called = true;
    return Uint8List.fromList(utf8.encode('<svg id="direct"></svg>'));
  }
}

void main() {
  late _FakeApi server;
  late _FakeDirectConverter direct;

  setUp(() async {
    server = _FakeApi();
    await server.start();
    direct = _FakeDirectConverter();
  });
  tearDown(() => server.stop());

  ApiConverter converter({
    String? token = 'tok',
    String? projectId = 'p1',
  }) =>
      ApiConverter(
        api: ProjectsApi(baseUrl: server.baseUrl),
        tokenProvider: () async => token,
        projectIdProvider: () async => projectId,
        fallback: direct,
      );

  test('сессия и проект: multipart в api → SVG через /content', () async {
    final svg = await converter().convertToSvg(
      fileName: 'label.cdr',
      bytes: Uint8List.fromList([1, 2, 3]),
    );

    expect(utf8.decode(svg), _FakeApi.svg);
    expect(server.log, [
      'POST /api/projects/p1/files',
      'GET /api/files/c1/content?format=svg',
    ]);
    expect(server.authHeaders, ['Bearer tok', 'Bearer tok']);
    expect(server.uploadBody, contains('convert'));
    expect(server.uploadBody, contains('label.cdr'));
    expect(direct.called, isFalse);
  });

  test('без токена: фолбэк на прямой services/converter', () async {
    final svg = await converter(token: null).convertToSvg(
      fileName: 'label.cdr',
      bytes: Uint8List.fromList([1]),
    );

    expect(direct.called, isTrue);
    expect(utf8.decode(svg), contains('direct'));
    expect(server.log, isEmpty);
  });

  test('без облачного проекта: фолбэк на прямой services/converter', () async {
    final svg = await converter(projectId: null).convertToSvg(
      fileName: 'label.ai',
      bytes: Uint8List.fromList([1]),
    );

    expect(direct.called, isTrue);
    expect(utf8.decode(svg), contains('direct'));
    expect(server.log, isEmpty);
  });

  test('ошибка api: русское сообщение как ConverterException', () async {
    server.denyUpload = true;
    try {
      await converter().convertToSvg(
        fileName: 'bad.cdr',
        bytes: Uint8List.fromList([9]),
      );
      fail('ожидался ConverterException');
    } on ConverterException catch (e) {
      expect(e.message, contains('Конвертация не удалась'));
    }
  });
}
