/// HTTP-реализация для web: dart:html HttpRequest (XHR).
///
/// dart:html объявлен устаревшим, но остаётся в SDK и даёт FormData/Blob/
/// ArrayBuffer без внешних пакетов — ровно то, что нужно проекту без
/// pub-зависимостей. Ответы JSON/текст берём как строку, бинарные — как
/// ArrayBuffer → Uint8List.
library;

import 'dart:async';
import 'dart:convert';
// ignore: deprecated_member_use -- dart:html остаётся: pub.dev недоступен, package:web не установить
import 'dart:html' as html;
import 'dart:typed_data';

import 'http.dart' show HttpResponse, NetworkException;

Future<HttpResponse> httpJsonPost(
  String url, {
  Map<String, String>? headers,
  Object? json,
  Duration timeout = const Duration(seconds: 8),
}) async {
  final body = json == null ? null : jsonEncode(json);
  return _send('POST', url,
      headers: _withJson(headers),
      body: body,
      responseType: 'text',
      timeout: timeout);
}

Future<HttpResponse> httpJsonGet(
  String url, {
  Map<String, String>? headers,
  Duration timeout = const Duration(seconds: 8),
}) =>
    _send('GET', url, headers: headers, timeout: timeout);

Future<HttpResponse> httpJsonPatch(
  String url, {
  Map<String, String>? headers,
  Object? json,
  Duration timeout = const Duration(seconds: 8),
}) async {
  final body = json == null ? null : jsonEncode(json);
  return _send('PATCH', url,
      headers: _withJson(headers),
      body: body,
      responseType: 'text',
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
}) async {
  final h = {...?headers};
  if (contentType != null && !h.containsKey('Content-Type')) {
    h['Content-Type'] = contentType;
  }
  return _send('POST', url,
      headers: h,
      body: body == null ? null : html.Blob([body]),
      responseType: 'arraybuffer',
      timeout: timeout);
}

Future<HttpResponse> httpRawGet(
  String url, {
  Map<String, String>? headers,
  Duration timeout = const Duration(seconds: 30),
}) =>
    _send('GET', url,
        headers: headers, responseType: 'arraybuffer', timeout: timeout);

Future<HttpResponse> httpMultipartPost(
  String url, {
  required String fieldName,
  required String fileName,
  required List<int> fileBytes,
  Map<String, String> fields = const {},
  Map<String, String>? headers,
  Duration timeout = const Duration(seconds: 30),
}) async {
  final fd = html.FormData();
  fields.forEach((k, v) => fd.append(k, v));
  // File — подкласс Blob с именем; appendBlob передаст filename серверу.
  final file = html.File([fileBytes], fileName);
  fd.appendBlob(fieldName, file, fileName);
  return _send('POST', url,
      headers: headers, body: fd, responseType: 'text', timeout: timeout);
}

Map<String, String>? _withJson(Map<String, String>? h) {
  final m = {...?h};
  m['Content-Type'] = 'application/json';
  return m;
}

Future<HttpResponse> _send(
  String method,
  String url, {
  Map<String, String>? headers,
  Object? body,
  String? responseType,
  Duration timeout = const Duration(seconds: 30),
}) async {
  final c = html.HttpRequest();
  try {
    c.open(method, url, async: true);
    if (responseType != null) c.responseType = responseType;
    headers?.forEach((k, v) => c.setRequestHeader(k, v));
    final completer = Completer<HttpResponse>();
    c.onError.listen((_) {
      if (!completer.isCompleted) {
        completer.completeError(
            const NetworkException('Сеть недоступна: соединение не установлено'));
      }
    });
    c.onLoad.listen((_) {
      if (completer.isCompleted) return;
      final headersOut = <String, String>{};
      c.responseHeaders.forEach((k, v) => headersOut[k] = v);
      completer.complete(HttpResponse(
        c.status ?? 0,
        _bodyBytes(c, responseType),
        headersOut,
      ));
    });
    c.timeout = timeout.inMilliseconds;
    c.send(body);
    return await completer.future.timeout(timeout,
        onTimeout: () =>
            throw TimeoutException('HTTP-запрос превысил таймаут', timeout));
  } finally {
    // HttpRequest не требует явного закрытия на web.
  }
}

Uint8List _bodyBytes(html.HttpRequest c, String? responseType) {
  final rt = responseType ?? c.responseType;
  if (rt == 'arraybuffer') {
    final ab = c.response;
    if (ab is ByteBuffer) {
      return ab.asUint8List(0, ab.lengthInBytes);
    }
    return Uint8List(0);
  }
  final text = c.responseText ?? '';
  return Uint8List.fromList(utf8.encode(text));
}
