// Тесты ProjectsApi и облачного режима ProjectStore против локального
// HTTP-сервера (контракт services/api §12.4, без внешних пакетов).
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:prepress_planner/license/account_client.dart';
import 'package:prepress_planner/src/projects/cloud_projects.dart';
import 'package:prepress_planner/src/projects/project.dart';

/// Локальный фейковый `services/api` (проекты + конверт ошибок §12.1).
class _FakeProjectsApi {
  HttpServer? _server;

  /// Лог запросов: 'METHOD /путь' (префикс /api сохраняется).
  final List<String> log = [];
  final List<String?> authHeaders = [];
  Map<String, dynamic>? lastBody;

  /// 403 plan_limit на POST /projects.
  bool denyCreate = false;

  final _projects = <String, Map<String, dynamic>>{};
  int _seq = 0;

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

  Future<Map<String, dynamic>> _body(HttpRequest req) async {
    final text = await utf8.decoder.bind(req).join();
    if (text.isEmpty) return {};
    try {
      final j = jsonDecode(text);
      if (j is Map) return j.cast<String, dynamic>();
    } on FormatException {
      // multipart/не-JSON: тело в тесте не используется.
    }
    return {};
  }

  void _json(HttpResponse resp, int status, Map<String, dynamic> body) {
    resp.statusCode = status;
    resp.headers.contentType = ContentType.json;
    resp.write(jsonEncode(body));
  }

  Map<String, dynamic> _projectJson(Map<String, dynamic> row) => {
        'id': row['id'],
        'org_id': 'org-test',
        'name': row['name'],
        'state': row['state'],
      };

  Future<void> _handle(HttpRequest req) async {
    final path = req.uri.path;
    log.add('${req.method} $path');
    authHeaders.add(req.headers.value('Authorization'));
    if (req.method == 'POST') lastBody = await _body(req);

    if (path == '/api/projects' && req.method == 'GET') {
      _json(req.response, 200, {
        'items': [for (final r in _projects.values) _projectJson(r)],
        'total': _projects.length,
        'org_id': 'org-test',
      });
      await req.response.close();
      return;
    }
    if (path == '/api/projects' && req.method == 'POST') {
      if (denyCreate) {
        _json(req.response, 403, {
          'error': {
            'code': 'plan_limit',
            'message': 'Тариф ограничивает число проектов (1). '
                'Оформите подписку Pro, чтобы создавать больше проектов.',
            'details': {'limit': 1},
          }
        });
        await req.response.close();
        return;
      }
      final id = 'p${++_seq}';
      final row = <String, dynamic>{
        'id': id,
        'name': lastBody?['name'],
        'state': lastBody?['state'],
      };
      _projects[id] = row;
      _json(req.response, 201,
          {'project_id': id, 'state': row['state'], 'project': _projectJson(row)});
      await req.response.close();
      return;
    }
    // Файлы §12.5: upload (без конвертации) + download blob.
    final f = RegExp(r'^/api/projects/(p\d+)/files$').firstMatch(path);
    if (f != null && req.method == 'POST') {
      _json(req.response, 201, {
        'file_id': 'f1',
        'project_id': f.group(1),
        'version': 1,
        'file': {'id': 'f1', 'name': 'label.dxf'},
      });
      await req.response.close();
      return;
    }
    if (path == '/api/files/f1/download' && req.method == 'GET') {
      req.response.statusCode = 200;
      req.response.headers.contentType =
          ContentType.parse('application/octet-stream');
      req.response.write('DXF-BYTES');
      await req.response.close();
      return;
    }

    // Отчёты §12.8: генерация + скачивание.
    final r = RegExp(r'^/api/projects/(p\d+)/reports/(pdf|xlsx|dxf)$')
        .firstMatch(path);
    if (r != null && req.method == 'POST') {
      _json(req.response, 200, {
        'project_id': r.group(1),
        'report': {'id': 'rep1', 'kind': r.group(2), 'size_bytes': 10},
        'download': '/reports/rep1/download',
      });
      await req.response.close();
      return;
    }
    if (path == '/api/reports/rep1/download' && req.method == 'GET') {
      req.response.statusCode = 200;
      req.response.headers.contentType = ContentType.parse('application/pdf');
      req.response.write('%PDF-fake');
      await req.response.close();
      return;
    }

    final m = RegExp(r'^/api/projects/(p\d+)$').firstMatch(path);
    if (m != null && _projects.containsKey(m.group(1))) {
      final row = _projects[m.group(1)]!;
      if (req.method == 'GET') {
        _json(req.response, 200, {'project': _projectJson(row)});
        await req.response.close();
        return;
      }
      if (req.method == 'PATCH') {
        if (lastBody?['name'] != null) row['name'] = lastBody!['name'];
        if (lastBody?['state'] != null) row['state'] = lastBody!['state'];
        _json(req.response, 200, {'project': _projectJson(row)});
        await req.response.close();
        return;
      }
      if (req.method == 'DELETE') {
        _projects.remove(m.group(1));
        req.response.statusCode = 204;
        await req.response.close();
        return;
      }
    }
    _json(req.response, 404,
        {'error': {'code': 'not_found', 'message': 'Не найдено.'}});
    await req.response.close();
  }
}

void main() {
  late _FakeProjectsApi server;
  const token = 'test-token';

  setUp(() async {
    server = _FakeProjectsApi();
    await server.start();
  });
  tearDown(() => server.stop());

  ProjectsApi api() => ProjectsApi(baseUrl: server.baseUrl);

  ProjectStore store() => ProjectStore(
        'projects',
        api: api(),
        tokenProvider: () async => token,
      );

  group('ProjectsApi', () {
    test('list: Bearer в заголовке, items разбираются', () async {
      await api().create(token, ' этикетка ', {'schemaVersion': 2});
      server.log.clear();
      server.authHeaders.clear();

      final items = await api().list(token);

      expect(items, hasLength(1));
      expect(items.first['name'], ' этикетка ');
      expect(server.log.single, 'GET /api/projects');
      expect(server.authHeaders.single, 'Bearer $token');
    });

    test('create + patch + get + delete: контракт §12.4', () async {
      final created =
          await api().create(token, 'Проект', {'schemaVersion': 2});
      final id = created['id'] as String;

      final patched = await api().patch(token, id,
          state: {'schemaVersion': 2, 'name': 'Проект'});
      expect(patched['id'], id);

      final got = await api().get(token, id);
      expect((got['state'] as Map)['schemaVersion'], 2);

      await api().delete(token, id);
      expect(server.log, contains('DELETE /api/projects/$id'));
    });

    test('ошибка403: русское сообщение из конверта error.message', () async {
      server.denyCreate = true;
      try {
        await api().create(token, 'X', {});
        fail('ожидался ApiException');
      } on ApiException catch (e) {
        expect(e.statusCode, 403);
        expect(e.message, contains('Тариф ограничивает число проектов'));
      }
    });

    test('generateReport + reportDownload: §12.8 транспорт', () async {
      final res = await api().generateReport(token, 'p1', 'pdf',
          state: {'name': 'Кампания'},
          layoutParams: {'labelW': 50},
          fontBase64: 'QUJD');

      expect(res['download'], '/reports/rep1/download');
      expect(server.log, contains('POST /api/projects/p1/reports/pdf'));
      expect(server.authHeaders.last, 'Bearer $token');
      expect(server.lastBody?['font_base64'], 'QUJD');
      expect((server.lastBody?['state'] as Map)['name'], 'Кампания');
      expect((server.lastBody?['layout_params'] as Map)['labelW'], 50);

      final bytes = await api().reportDownload(token, res['download'] as String);
      expect(utf8.decode(bytes), '%PDF-fake');
      expect(server.log.last, 'GET /api/reports/rep1/download');
    });

    test('uploadFile + downloadFile: §12.5 файлы', () async {
      final res = await api()
          .uploadFile(token, 'p1', 'label.dxf', [68, 88, 70]);
      expect(res['file_id'], 'f1');
      expect(server.log.single, 'POST /api/projects/p1/files');
      expect(server.authHeaders.single, 'Bearer $token');

      final bytes = await api().downloadFile(token, 'f1');
      expect(utf8.decode(bytes), 'DXF-BYTES');
      expect(server.log.last, 'GET /api/files/f1/download');
    });
  });

  group('ProjectStore (облачный режим)', () {
    test('save → create; повторный save → patch; load/listNames', () async {
      final s = store();
      final p = Project(name: 'Кампания', inputFile: 'label.dxf');

      await s.save(p);
      // save сначала ищет проект с таким именем (GET), затем создаёт.
      expect(server.log, contains('GET /api/projects'));
      expect(server.log, contains('POST /api/projects'));

      // Повторное сохранение того же имени — PATCH состояния, не дубль.
      await s.save(p);
      expect(server.log.where((l) => l.startsWith('POST')).length, 1);
      expect(server.log, contains('PATCH /api/projects/p1'));

      final names = await s.listNames();
      expect(names, ['Кампания']);

      final loaded = await s.load('Кампания');
      expect(loaded, isNotNull);
      expect(loaded!.inputFile, 'label.dxf');
      expect(loaded.name, 'Кампания');

      expect(await s.load('Нет такого'), isNull);
    });

    test('без токена: локальный режим, запросы в api не уходят', () async {
      final s = ProjectStore(
        'projects',
        api: api(),
        tokenProvider: () async => '',
      );
      server.log.clear();

      await s.listNames();

      expect(server.log, isEmpty);
    });

    test('uploadSource: file_id из облака; без токена — null без запросов',
        () async {
      final id = await store()
          .uploadSource(Project(name: 'Кампания'), 'label.dxf', [68, 88, 70]);
      expect(id, 'f1');
      expect(server.log, contains('POST /api/projects')); // ensureCloudId
      expect(server.log, contains('POST /api/projects/p1/files'));

      final local = ProjectStore('projects',
          api: api(), tokenProvider: () async => null);
      server.log.clear();
      expect(await local.uploadSource(Project(name: 'X'), 'a.dxf', [1]), isNull);
      expect(server.log, isEmpty);
    });
  });
}
