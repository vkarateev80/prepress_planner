/// Клиент `services/api` — проекты в облаке (§12.4 System Design).
///
/// Используется `ProjectStore` в web-сборке при активной сессии аккаунта
/// (задача `flutter-web-adapt`); иначе хранилище остаётся локальным.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../../license/account_client.dart' show ApiException;
import '../../platform/env.dart';
import '../../platform/http.dart';

/// CRUD проектов: `GET/POST /api/projects`, `GET/PATCH/DELETE /api/projects/{id}`.
class ProjectsApi {
  final String baseUrl;

  ProjectsApi({String? baseUrl}) : baseUrl = baseUrl ?? defaultUrl();

  /// Адрес по умолчанию: env (desktop) либо тот же origin (web, ADR-6).
  static String defaultUrl() =>
      envOrDefault('PP_API_URL', isWeb ? '/api' : 'http://127.0.0.1:8100/api');

  static const _timeout = Duration(seconds: 15);
  static const _unavailable = ApiException(
      'Сервис проектов недоступен. Проверьте сеть и авторизацию.');
  static const _noAnswer = ApiException('Сервис проектов не отвечает.');

  String get _base => baseUrl.endsWith('/')
      ? baseUrl.substring(0, baseUrl.length - 1)
      : baseUrl;

  Map<String, String> _auth(String token) =>
      {'Authorization': 'Bearer $token'};

  /// Список проектов организации: `[{id, name, state, ...}]`.
  Future<List<Map<String, dynamic>>> list(String token) async {
    final j = await _request('GET', '/projects', token);
    final items = j['items'] as List? ?? const [];
    return [for (final e in items) (e as Map).cast<String, dynamic>()];
  }

  /// Метаданные проекта (включая `state` — project_state.json v2).
  Future<Map<String, dynamic>> get(String token, String id) async {
    final j = await _request('GET', '/projects/$id', token);
    return (j['project'] as Map).cast<String, dynamic>();
  }

  /// Создать проект; возвращает метаданные.
  Future<Map<String, dynamic>> create(
      String token, String name, Map<String, dynamic> state) async {
    final j = await _request('POST', '/projects', token,
        body: {'name': name, 'state': state});
    return (j['project'] as Map).cast<String, dynamic>();
  }

  /// Обновить имя и/или состояние проекта.
  Future<Map<String, dynamic>> patch(String token, String id,
      {String? name, Map<String, dynamic>? state}) async {
    final body = <String, dynamic>{
      if (name != null) 'name': name,
      if (state != null) 'state': state,
    };
    final j = await _request('PATCH', '/projects/$id', token, body: body);
    return (j['project'] as Map).cast<String, dynamic>();
  }

  /// Мягкое удаление проекта.
  Future<void> delete(String token, String id) =>
      _request('DELETE', '/projects/$id', token);

  /// Загрузить файл и **синхронно** конвертировать (ADR-7, form `convert`).
  /// Ответ содержит `converted_file_id` — результат в объектном хранилище.
  Future<Map<String, dynamic>> uploadAndConvert(
    String token,
    String projectId,
    String fileName,
    List<int> bytes, {
    String target = 'svg',
  }) async {
    try {
      final resp = await httpMultipartPost(
        '$_base/projects/$projectId/files',
        headers: _auth(token),
        fieldName: 'file',
        fileName: fileName,
        fileBytes: bytes,
        fields: {'convert': target},
        // Синхронная конвертация на сервере может идти десятки секунд
        // (nginx proxy_read_timeout 120–220s).
        timeout: const Duration(seconds: 240),
      );
      return _jsonOrThrow(resp.status, resp.text);
    } on ApiException {
      rethrow;
    } on TimeoutException {
      throw _noAnswer;
    } on NetworkException {
      throw _unavailable;
    }
  }

  /// Содержимое файла потоком: `GET /files/{id}/content?format=svg|pdf|original`.
  Future<Uint8List> fileContent(String token, String fileId,
      {String format = 'svg'}) async {
    try {
      final resp = await httpRawGet('$_base/files/$fileId/content?format=$format',
          headers: _auth(token), timeout: _timeout);
      if (resp.status >= 200 && resp.status < 300) return resp.body;
      throw ApiException(_detail(resp.text), statusCode: resp.status);
    } on ApiException {
      rethrow;
    } on TimeoutException {
      throw _noAnswer;
    } on NetworkException {
      throw _unavailable;
    }
  }

  /// Загрузить исходный файл без конвертации (§12.5, picker → multipart):
  /// метаданные + blob в хранилище. Ответ содержит `file_id`.
  Future<Map<String, dynamic>> uploadFile(
    String token,
    String projectId,
    String fileName,
    List<int> bytes, {
    String fileType = 'original',
  }) async {
    try {
      final resp = await httpMultipartPost(
        '$_base/projects/$projectId/files',
        headers: _auth(token),
        fieldName: 'file',
        fileName: fileName,
        fileBytes: bytes,
        fields: {'file_type': fileType},
        timeout: const Duration(seconds: 120),
      );
      return _jsonOrThrow(resp.status, resp.text);
    } on ApiException {
      rethrow;
    } on TimeoutException {
      throw _noAnswer;
    } on NetworkException {
      throw _unavailable;
    }
  }

  /// Скачать blob файла: `GET /files/{id}/download` (stream, §12.5).
  Future<Uint8List> downloadFile(String token, String fileId) async {
    try {
      final resp = await httpRawGet('$_base/files/$fileId/download',
          headers: _auth(token), timeout: _timeout);
      if (resp.status >= 200 && resp.status < 300) return resp.body;
      throw ApiException(_detail(resp.text), statusCode: resp.status);
    } on ApiException {
      rethrow;
    } on TimeoutException {
      throw _noAnswer;
    } on NetworkException {
      throw _unavailable;
    }
  }

  /// Сгенерировать отчёт на сервере (§12.8): `POST /projects/{id}/reports/{fmt}`.
  /// Ответ: `{project_id, report, download}` — `download` относительный путь
  /// для [reportDownload].
  Future<Map<String, dynamic>> generateReport(
    String token,
    String projectId,
    String fmt, {
    Map<String, dynamic>? state,
    Map<String, dynamic>? layoutParams,
    String? fontBase64,
    String? paths,
  }) =>
      _request('POST', '/projects/$projectId/reports/$fmt', token,
          body: {
            if (layoutParams != null) 'layout_params': layoutParams,
            if (state != null) 'state': state,
            if (fontBase64 != null) 'font_base64': fontBase64,
            if (paths != null) 'paths': paths,
          });

  /// Скачать отчёт потоком: `GET {base}{download}` (Bearer, §12.8).
  Future<Uint8List> reportDownload(String token, String downloadPath) async {
    final path = downloadPath.startsWith('/') ? downloadPath : '/$downloadPath';
    try {
      final resp = await httpRawGet('$_base$path',
          headers: _auth(token), timeout: _timeout);
      if (resp.status >= 200 && resp.status < 300) return resp.body;
      throw ApiException(_detail(resp.text), statusCode: resp.status);
    } on ApiException {
      rethrow;
    } on TimeoutException {
      throw _noAnswer;
    } on NetworkException {
      throw _unavailable;
    }
  }

  Future<Map<String, dynamic>> _request(
      String method, String path, String token,
      {Object? body}) async {
    try {
      final headers = _auth(token);
      final resp = await switch (method) {
        'GET' => httpJsonGet('$_base$path',
            headers: headers, timeout: _timeout),
        'DELETE' => httpJsonDelete('$_base$path',
            headers: headers, timeout: _timeout),
        'PATCH' => httpJsonPatch('$_base$path',
            headers: headers, json: body, timeout: _timeout),
        _ => httpJsonPost('$_base$path',
            headers: headers, json: body, timeout: _timeout),
      };
      if (resp.status == 204 || resp.text.isEmpty) return const {};
      return _jsonOrThrow(resp.status, resp.text);
    } on ApiException {
      rethrow;
    } on TimeoutException {
      throw _noAnswer;
    } on NetworkException {
      throw _unavailable;
    }
  }

  Map<String, dynamic> _jsonOrThrow(int status, String text) {
    if (status >= 200 && status < 300) {
      if (text.isEmpty) return const {};
      Object? parsed;
      try {
        parsed = jsonDecode(text);
      } on FormatException {
        // Прод-страховка: например, SPA-handler вернул index.html из-за
        // неверного префикса адреса (PP_API_URL) — раньше это роняло
        // непойманным исключением.
        throw const ApiException(
            'Сервис проектов вернул не-JSON ответ — проверьте адрес API.');
      }
      if (parsed is! Map) {
        throw const ApiException(
            'Сервис проектов вернул некорректный ответ.');
      }
      return parsed.cast<String, dynamic>();
    }
    throw ApiException(_detail(text), statusCode: status);
  }

  /// Русское сообщение из конверта `{"error": {code, message}}` (§12.1).
  static String _detail(String text) {
    try {
      final j = jsonDecode(text);
      if (j is Map) {
        final err = j['error'];
        if (err is Map && err['message'] != null) {
          return err['message'].toString();
        }
        if (j['detail'] != null) return j['detail'].toString();
      }
    } catch (_) {}
    return text.isEmpty ? 'ошибка сервера' : text.trim();
  }
}
