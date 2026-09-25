/// HTTP-клиент к сервису конвертации закрытых форматов.
///
/// services/converter (FastAPI): AI/CDR/EPS → SVG/PDF. Внешних pub-пакетов
/// нет: общий HTTP-слой платформы (dart:io / XHR). Файл передаётся БАЙТАМИ
/// (на web файловой системы нет). Контракт сервиса:
///   POST /convert         multipart: file + target(svg|pdf) → {job_id}
///   GET  /convert/{id}    → {status: pending|running|done|error,
///                            result_url, error}
///   GET  result_url       статика /data/out/<job>/result.<ext>
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../../platform/env.dart';
import '../../platform/http.dart';

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
  /// [fileName] — имя исходного файла (по расширению определяется формат),
  /// [bytes] — содержимое файла.
  Future<Uint8List> convertToSvg(
      {required String fileName, required Uint8List bytes});
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

  /// Адрес по умолчанию: env `PP_CONVERTER_URL` (desktop/VM), на web — тот же
  /// origin (ADR-1/ADR-6).
  ///
  /// Зашитый IP удалён (ADR-6): в браузере env нет (`env_web.dart` возвращает
  /// пусто), поэтому «пусто» означает **относительные URL того же origin** —
  /// `/convert`, `/data/out/...` проксирует edge nginx. Пустая строка вместо
  /// IP исключает обращения к чужому/устаревшему серверу.
  static String defaultBaseUrl() =>
      envOrDefault('PP_CONVERTER_URL', '').trim();

  static const _closedExts = {'.ai', '.cdr', '.eps'};

  /// Поддерживает ли имя файла закрытый формат (AI/CDR/EPS).
  static bool isClosedFormat(String fileName) {
    final i = fileName.lastIndexOf('.');
    if (i < 0) return false;
    return _closedExts.contains(fileName.substring(i).toLowerCase());
  }

  static const _reqTimeout = Duration(seconds: 30);

  @override
  Future<Uint8List> convertToSvg(
      {required String fileName, required Uint8List bytes}) async {
    final ext = _sourceExt(fileName);
    if (!_closedExts.contains(ext)) {
      throw ConverterException(
          'Формат «$ext» не конвертируется: допустимы AI, CDR, EPS.');
    }
    final deadline = DateTime.now().add(timeout);
    try {
      final jobId = await _postJob(bytes, ext, deadline, fileName);
      final resultUrl = await _pollJob(jobId, deadline);
      return await _download(resultUrl, deadline);
    } on ConverterException {
      rethrow;
    } on TimeoutException {
      throw const ConverterException(
          'Сервер конвертации не отвечает (превышено время ожидания запроса).');
    } on NetworkException catch (e) {
      throw ConverterException(
          'Сервис конвертации недоступен: ${e.message}. '
          'Проверьте подключение к серверу конвертации.');
    }
  }

  static String _sourceExt(String fileName) {
    final i = fileName.lastIndexOf('.');
    return i < 0 ? '' : fileName.substring(i).toLowerCase();
  }

  String _base() {
    final b = baseUrl.endsWith('/')
        ? baseUrl.substring(0, baseUrl.length - 1)
        : baseUrl;
    return b;
  }

  void _checkDeadline(DateTime deadline, String what) {
    if (DateTime.now().isAfter(deadline)) {
      throw ConverterException(
          'Конвертация «$what» не завершилась за ${timeout.inSeconds} с. '
          'Проверьте сервер конвертации и повторите.');
    }
  }

  Future<String> _postJob(Uint8List bytes, String ext, DateTime deadline,
      String fileName) async {
    _checkDeadline(deadline, fileName);
    // Имя «import$ext» как раньше: серверу важно расширение файлового поля.
    final base = _base();
    final resp = await httpMultipartPost('$base/convert',
        fieldName: 'file',
        fileName: 'import$ext',
        fileBytes: bytes,
        fields: const {'target': 'svg'},
        timeout: _reqTimeout);
    final text = resp.text;
    final j = _tryJson(text);
    if (resp.status == 200 && j is Map && j['job_id'] is String) {
      return j['job_id'] as String;
    }
    // FastAPI возвращает детали в {"detail": ...} (строка или список).
    if (resp.status == 200 || resp.status >= 500) {
      throw ConverterException(
          'Сервер не принял задачу (${resp.status}): ${_detail(text)}');
    }
    throw ConverterException(
        'Сервер отклонил файл (${resp.status}): ${_detail(text)}');
  }

  Future<String> _pollJob(String jobId, DateTime deadline) async {
    while (true) {
      _checkDeadline(deadline, jobId);
      final j = await _jsonGet('/convert/$jobId');
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

  Future<Map<String, dynamic>> _jsonGet(String path) async {
    final base = _base();
    final resp = await httpJsonGet('$base$path', timeout: _reqTimeout);
    if (resp.status != 200) {
      throw ConverterException(
          'Сервер ответил ошибкой (${resp.status}): ${_detail(resp.text)}');
    }
    final j = _tryJson(resp.text);
    if (j is! Map<String, dynamic>) {
      throw const ConverterException(
          'Некорректный ответ сервера конвертации.');
    }
    return j;
  }

  /// Скачивание результата: [resultUrl] может быть абсолютным или
  /// относительным (в т.ч. '/data/out/...' при проксировании одним origin).
  Future<Uint8List> _download(String resultUrl, DateTime deadline) async {
    _checkDeadline(deadline, resultUrl);
    final low = resultUrl.toLowerCase();
    final base = _base();
    final full = low.startsWith('http://') || low.startsWith('https://')
        ? resultUrl
        : resultUrl.startsWith('/')
            ? '$base$resultUrl'
            : '$base/$resultUrl';
    final resp = await httpRawGet(full, timeout: _reqTimeout);
    if (resp.status != 200) {
      throw ConverterException(
          'Не удалось скачать результат (${resp.status}): '
          '${_detail(resp.text)}');
    }
    return resp.body;
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
