/// HTTP-клиент к сервису конвертации закрытых форматов.
///
/// services/converter (FastAPI): AI/CDR/EPS → SVG/PDF. Внешних pub-пакетов
/// нет (правило проекта), поэтому multipart/form-data собирается вручную
/// на dart:io. Контракт сервиса:
///   POST /convert         multipart: file + target(svg|pdf) → {job_id}
///   GET  /convert/{id}    → {status: pending|running|done|error,
///                            result_url, error}
///   GET  result_url       статика /data/out/<job>/result.<ext>
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Ошибка конвертации с русским сообщением для UI.
class ConverterException implements Exception {
  final String message;
  const ConverterException(this.message);

  @override
  String toString() => message;
}

/// Абстракция конвертера (в тестах подменяется заглушкой).
abstract class Converter {
  String get baseUrl;

  /// Конвертирует закрытый формат (AI/CDR/EPS) в SVG и возвращает байты.
  Future<Uint8List> convertToSvg(File source);
}

/// Реальный клиент к services/converter (FastAPI, порт 8120).
class ConverterApi implements Converter {
  @override
  final String baseUrl;

  /// Пауза между опросами статуса джобы.
  final Duration pollInterval;

  /// Общее время ожидания конвертации.
  final Duration timeout;

  ConverterApi({
    String? baseUrl,
    this.pollInterval = const Duration(milliseconds: 600),
    this.timeout = const Duration(seconds: 180),
  }) : baseUrl = baseUrl ?? defaultBaseUrl();

  /// Адрес по умолчанию: env PP_CONVERTER_URL либо VPS-сервер конвертации.
  static String defaultBaseUrl() {
    final env = Platform.environment['PP_CONVERTER_URL'];
    if (env != null && env.trim().isNotEmpty) return env.trim();
    return 'http://193.233.193.12:8120';
  }

  static const _closedExts = {'.ai', '.cdr', '.eps'};

  /// Поддерживает ли путь закрытый формат (AI/CDR/EPS).
  static bool isClosedFormat(String path) {
    final i = path.lastIndexOf('.');
    if (i < 0) return false;
    return _closedExts.contains(path.substring(i).toLowerCase());
  }

  static const _reqTimeout = Duration(seconds: 30);

  @override
  Future<Uint8List> convertToSvg(File source) async {
    final ext = _sourceExt(source.path);
    if (!_closedExts.contains(ext)) {
      throw ConverterException(
          'Формат «$ext» не конвертируется: допустимы AI, CDR, EPS.');
    }
    final boundary = '----pp_${DateTime.now().microsecondsSinceEpoch}';
    final body = await _multipartBody(source, ext, boundary);
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    final deadline = DateTime.now().add(timeout);
    try {
      final jobId =
          await _postJob(client, body, boundary, deadline, source.path);
      final resultUrl = await _pollJob(client, jobId, deadline);
      return await _download(client, resultUrl, deadline);
    } on ConverterException {
      rethrow;
    } on TimeoutException {
      throw const ConverterException(
          'Сервер конвертации не отвечает (превышено время ожидания запроса).');
    } on SocketException catch (e) {
      throw ConverterException(
          'Сервис конвертации недоступен ($baseUrl): '
          '${e.osError?.message ?? e.message}. '
          'Запустите сервис: uvicorn converter_app.main:app --port 8120');
    } on HttpException catch (e) {
      throw ConverterException('Ошибка HTTP при обращении к серверу: ${e.message}');
    } finally {
      client.close(force: true);
    }
  }

  static String _sourceExt(String path) {
    final i = path.lastIndexOf('.');
    return i < 0 ? '' : path.substring(i).toLowerCase();
  }

  Uri _uri(String path) {
    final base = baseUrl.endsWith('/')
        ? baseUrl.substring(0, baseUrl.length - 1)
        : baseUrl;
    return Uri.parse('$base$path');
  }

  Future<Uint8List> _multipartBody(
      File source, String ext, String boundary) async {
    final fileBytes = await source.readAsBytes();
    final head = utf8.encode(
        '--$boundary\r\n'
        'Content-Disposition: form-data; name="file"; '
        'filename="import$ext"\r\n'
        'Content-Type: application/octet-stream\r\n\r\n');
    final tail = utf8.encode(
        '\r\n--$boundary\r\n'
        'Content-Disposition: form-data; name="target"\r\n\r\n'
        'svg\r\n--$boundary--\r\n');
    final builder = BytesBuilder(copy: false)
      ..add(head)
      ..add(fileBytes)
      ..add(tail);
    return builder.takeBytes();
  }

  void _checkDeadline(DateTime deadline, String fileName) {
    if (DateTime.now().isAfter(deadline)) {
      throw ConverterException(
          'Конвертация «$fileName» не завершилась за ${timeout.inSeconds} с. '
          'Проверьте сервер конвертации и повторите.');
    }
  }

  Future<String> _postJob(HttpClient client, Uint8List body,
      String boundary, DateTime deadline, String fileName) async {
    _checkDeadline(deadline, fileName);
    final req = await client.postUrl(_uri('/convert')).timeout(_reqTimeout);
    req.headers.set(HttpHeaders.contentTypeHeader,
        'multipart/form-data; boundary=$boundary');
    req.headers.set(HttpHeaders.contentLengthHeader, body.length);
    req.add(body);
    final resp = await req.close().timeout(_reqTimeout);
    final text = await utf8.decodeStream(resp).timeout(_reqTimeout);
    final j = _tryJson(text);
    if (resp.statusCode == 200 && j is Map && j['job_id'] is String) {
      return j['job_id'] as String;
    }
    // FastAPI возвращает детали в {"detail": ...} (строка или список).
    if (resp.statusCode == 200 || resp.statusCode >= 500) {
      throw ConverterException(
          'Сервер не принял задачу (${resp.statusCode}): ${_detail(text)}');
    }
    throw ConverterException(
        'Сервер отклонил файл (${resp.statusCode}): ${_detail(text)}');
  }

  Future<String> _pollJob(
      HttpClient client, String jobId, DateTime deadline) async {
    while (true) {
      _checkDeadline(deadline, jobId);
      final j = await _jsonGet(client, '/convert/$jobId');
      final status = j['status'];
      if (status == 'done') {
        final url = j['result_url'];
        if (url is String && url.isNotEmpty) return url;
        throw const ConverterException(
            'Сервер не вернул ссылку на результат конвертации.');
      }
      if (status == 'error') {
        final err = j['error'];
        throw ConverterException(err is String && err.isNotEmpty
            ? 'Конвертация не выполнена: $err'
            : 'Конвертация не выполнена (ошибка на сервере).');
      }
      if (status != 'pending' && status != 'running') {
        throw ConverterException(
            'Неизвестный статус задачи от сервера: $status');
      }
      await Future<void>.delayed(pollInterval);
    }
  }

  Future<Map<String, dynamic>> _jsonGet(
      HttpClient client, String path) async {
    final req = await client.getUrl(_uri(path)).timeout(_reqTimeout);
    final resp = await req.close().timeout(_reqTimeout);
    final text = await utf8.decodeStream(resp).timeout(_reqTimeout);
    if (resp.statusCode != 200) {
      throw ConverterException(
          'Сервер ответил ошибкой (${resp.statusCode}): ${_detail(text)}');
    }
    final j = _tryJson(text);
    if (j is! Map<String, dynamic>) {
      throw const ConverterException(
          'Некорректный ответ сервера конвертации.');
    }
    return j;
  }

  Future<Uint8List> _download(
      HttpClient client, String resultUrl, DateTime deadline) async {
    _checkDeadline(deadline, resultUrl);
    final req = await client.getUrl(_uri(resultUrl)).timeout(_reqTimeout);
    final resp = await req.close().timeout(_reqTimeout);
    if (resp.statusCode != 200) {
      final text = await utf8.decodeStream(resp).timeout(_reqTimeout);
      throw ConverterException(
          'Не удалось скачать результат (${resp.statusCode}): '
          '${_detail(text)}');
    }
    final builder = BytesBuilder(copy: false);
    await for (final chunk in resp) {
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  static Object? _tryJson(String text) {
    try {
      return jsonDecode(text);
    } catch (_) {
      return null;
    }
  }

  static String _detail(String text) {
    final j = _tryJson(text);
    if (j is Map) {
      final d = j['detail'];
      if (d is String) return d;
      if (d is List && d.isNotEmpty) {
        final first = d.first;
        if (first is Map && first['msg'] != null) {
          return first['msg'].toString();
        }
      }
      if (d != null) return d.toString();
    }
    return text.isEmpty ? 'нет данных' : text.trim();
  }
}
