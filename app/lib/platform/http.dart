/// Кроссплатформенный HTTP: dart:io (VM/desktop) и XHR (web).
///
/// Внешних pub-пакетов нет (правило проекта). Общий API — функции в конце
/// файла; реализация подставляется условным импортом: `http_impl_io.dart`
/// на VM/desktop, `http_impl_web.dart` в браузере (dart:html HttpRequest).
library;

import 'dart:convert';
import 'dart:typed_data';

import 'http_impl_io.dart' if (dart.library.html) 'http_impl_web.dart'
    as impl;

/// Ошибка сети/транспорта (сервер недоступен, DNS, соединение закрыто).
/// Семантически заменяет SocketException/ClientException на всех платформах.
class NetworkException implements Exception {
  final String message;
  const NetworkException(this.message);
  @override
  String toString() => message;
}

/// Ответ HTTP: статус, тело (байты + текст), заголовки.
class HttpResponse {
  final int status;
  final Uint8List body;
  final Map<String, String> headers;
  const HttpResponse(this.status, this.body, this.headers);

  String get text => utf8.decode(body, allowMalformed: true);
}

Future<HttpResponse> httpJsonPost(
  String url, {
  Map<String, String>? headers,
  Object? json,
  Duration timeout = const Duration(seconds: 8),
}) =>
    impl.httpJsonPost(url,
        headers: headers, json: json, timeout: timeout);

Future<HttpResponse> httpJsonGet(
  String url, {
  Map<String, String>? headers,
  Duration timeout = const Duration(seconds: 8),
}) =>
    impl.httpJsonGet(url, headers: headers, timeout: timeout);

Future<HttpResponse> httpJsonPatch(
  String url, {
  Map<String, String>? headers,
  Object? json,
  Duration timeout = const Duration(seconds: 8),
}) =>
    impl.httpJsonPatch(url,
        headers: headers, json: json, timeout: timeout);

Future<HttpResponse> httpJsonDelete(
  String url, {
  Map<String, String>? headers,
  Duration timeout = const Duration(seconds: 8),
}) =>
    impl.httpJsonDelete(url, headers: headers, timeout: timeout);

Future<HttpResponse> httpRawPost(
  String url, {
  Map<String, String>? headers,
  List<int>? body,
  String? contentType,
  Duration timeout = const Duration(seconds: 30),
}) =>
    impl.httpRawPost(url,
        headers: headers, body: body, contentType: contentType, timeout: timeout);

Future<HttpResponse> httpRawGet(
  String url, {
  Map<String, String>? headers,
  Duration timeout = const Duration(seconds: 30),
}) =>
    impl.httpRawGet(url, headers: headers, timeout: timeout);

/// Multipart/form-data: одно файловое поле + текстовые поля.
Future<HttpResponse> httpMultipartPost(
  String url, {
  required String fieldName,
  required String fileName,
  required List<int> fileBytes,
  Map<String, String> fields = const {},
  Map<String, String>? headers,
  Duration timeout = const Duration(seconds: 30),
}) =>
    impl.httpMultipartPost(
      url,
      fieldName: fieldName,
      fileName: fileName,
      fileBytes: fileBytes,
      fields: fields,
      headers: headers,
      timeout: timeout,
    );
