/// Разбор и подготовка JSON-запроса воркера.
///
/// Все ошибки структуры запроса превращаются в [WorkerError] с русским
/// сообщением и кодом `bad_request` (схема `{"error":{"code","message"}}`).
library;

import 'dart:convert';

import 'errors.dart';

/// Разобрать тело запроса в объект-запрос воркера.
///
/// [rawBody] — уже прочитанное тело (строка). Тело должно быть JSON-объектом;
/// поддерживаются синонимы ключей (`state` → `appState`).
Map<String, dynamic> parseRequestBody(String rawBody) {
  final trimmed = rawBody.trim();
  if (trimmed.isEmpty) {
    throw WorkerError.badRequest(
        'Пустое тело запроса: ожидается JSON с макетом и стадиями.');
  }
  Object? decoded;
  try {
    decoded = jsonDecode(trimmed);
  } on FormatException catch (e) {
    throw WorkerError.badRequest('Некорректный JSON в теле запроса: '
        '${e.message} (позиция ${e.offset}).');
  }
  if (decoded is! Map) {
    throw WorkerError.badRequest(
        'Тело запроса должно быть JSON-объектом, получено: '
        '${decoded.runtimeType}.');
  }
  return normalize(decoded.cast<String, dynamic>());
}

/// Нормализовать ключи запроса (синонимы) и подставить значения по умолчанию.
Map<String, dynamic> normalize(Map<String, dynamic> body) {
  final req = Map<String, dynamic>.from(body);
  if (req['appState'] == null && req['state'] is Map) {
    req['appState'] = req['state'];
  }
  if (req['teoInput'] == null && req['teo'] is Map) {
    req['teoInput'] = req['teo'];
  }
  // file_base64 может лежать в appState (клиент складывает туда всё состояние).
  final appState = req['appState'];
  if (req['file_base64'] == null && appState is Map && appState['file_base64'] != null) {
    req['file_base64'] = appState['file_base64'];
    if (req['fileName'] == null && appState['fileName'] != null) {
      req['fileName'] = appState['fileName'];
    }
  }
  req['includeRawPaths'] = req['includeRawPaths'] != false;
  return req;
}
