/// HTTP-реализация для VM/desktop: dart:io HttpClient.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'http.dart' show HttpResponse, NetworkException;

Future<HttpResponse> httpJsonPost(
  String url, {
  Map<String, String>? headers,
  Object? json,
  Duration timeout = const Duration(seconds: 8),
}) {
  final body = json == null ? null : jsonEncode(json);
  return httpRawPost(url,
      headers: headers, body: body == null ? null : utf8.encode(body),
      contentType: 'application/json', timeout: timeout);
}

Future<HttpResponse> httpJsonGet(
  String url, {
  Map<String, String>? headers,
  Duration timeout = const Duration(seconds: 8),
}) =>
    httpRawGet(url, headers: headers, timeout: timeout);

Future<HttpResponse> httpJsonPatch(
  String url, {
  Map<String, String>? headers,
  Object? json,
  Duration timeout = const Duration(seconds: 8),
}) {
  final body = json == null ? null : jsonEncode(json);
  return _send('PATCH', url,
      headers: headers,
      body: body == null ? null : utf8.encode(body),
      contentType: 'application/json',
      timeout: timeout);
}

Future<HttpResponse> httpJsonDelete(
  String url, {
  Map<String, String>? headers,
  Duration timeout = const Duration(seconds: 8),
}) =>
    _send('DELETE', url, headers: headers, timeout: timeout);

Future<HttpResponse> httpRawPost(
  String url, {
  Map<String, String>? headers,
  List<int>? body,
  String? contentType,
  Duration timeout = const Duration(seconds: 30),
}) =>
    _send('POST', url,
        headers: headers,
        body: body,
        contentType: contentType,
        timeout: timeout);

Future<HttpResponse> _send(
  String method,
  String url, {
  Map<String, String>? headers,
  List<int>? body,
  String? contentType,
  Duration timeout = const Duration(seconds: 30),
}) async {
  final client = HttpClient()..connectionTimeout = timeout;
  try {
    final req = await client.openUrl(method, Uri.parse(url)).timeout(timeout);
    if (contentType != null) {
      req.headers.contentType = ContentType.parse(contentType);
    }
    _applyHeaders(req, headers);
    if (body != null) req.add(body);
    final resp = await req.close().timeout(timeout);
    return await _collect(resp, timeout);
  } on SocketException catch (e) {
    throw NetworkException(e.osError?.message ?? e.message);
  } on HttpException catch (e) {
    throw NetworkException(e.message);
  } finally {
    client.close(force: true);
  }
}

Future<HttpResponse> httpRawGet(
  String url, {
  Map<String, String>? headers,
  Duration timeout = const Duration(seconds: 30),
}) async {
  final client = HttpClient()..connectionTimeout = timeout;
  try {
    final req = await client.getUrl(Uri.parse(url)).timeout(timeout);
    _applyHeaders(req, headers);
    final resp = await req.close().timeout(timeout);
    return await _collect(resp, timeout);
  } on SocketException catch (e) {
    throw NetworkException(e.osError?.message ?? e.message);
  } on HttpException catch (e) {
    throw NetworkException(e.message);
  } finally {
    client.close(force: true);
  }
}

Future<HttpResponse> httpMultipartPost(
  String url, {
  required String fieldName,
  required String fileName,
  required List<int> fileBytes,
  Map<String, String> fields = const {},
  Map<String, String>? headers,
  Duration timeout = const Duration(seconds: 30),
}) async {
  final boundary = '----pp_${DateTime.now().microsecondsSinceEpoch}';
  final buf = BytesBuilder(copy: false);
  void part(String name, String value, {String? filename, String? fileType}) {
    buf.add(utf8.encode(
        '--$boundary\r\n'
        'Content-Disposition: form-data; name="$name"'
        '${filename == null ? '' : '; filename="$filename"'}\r\n'
        '${fileType == null ? '' : 'Content-Type: $fileType\r\n'}\r\n'));
    buf.add(utf8.encode(value));
    buf.add(utf8.encode('\r\n'));
  }

  for (final e in fields.entries) {
    part(e.key, e.value);
  }
  // Файловое поле.
  buf.add(utf8.encode(
      '--$boundary\r\n'
      'Content-Disposition: form-data; name="$fieldName"; '
      'filename="$fileName"\r\n'
      'Content-Type: application/octet-stream\r\n\r\n'));
  buf.add(fileBytes);
  buf.add(utf8.encode('\r\n--$boundary--\r\n'));
  return httpRawPost(url,
      headers: headers,
      body: buf.takeBytes(),
      contentType: 'multipart/form-data; boundary=$boundary',
      timeout: timeout);
}

void _applyHeaders(HttpClientRequest req, Map<String, String>? headers) {
  headers?.forEach((k, v) => req.headers.set(k, v));
}

Future<HttpResponse> _collect(HttpClientResponse resp, Duration timeout) async {
  final headers = <String, String>{};
  resp.headers.forEach((k, v) => headers[k] = v.join(', '));
  final b = BytesBuilder(copy: false);
  await for (final chunk in resp) {
    b.add(chunk);
  }
  final body = b.takeBytes();
  return HttpResponse(resp.statusCode, body, headers);
}
