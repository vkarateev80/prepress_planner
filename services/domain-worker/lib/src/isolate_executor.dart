/// Исполнение доменных стадий в изолятах `dart:io` (`Isolate.spawn`).
///
/// Зачем (ADR-2, N-3): лечение тяжёлого макета ~16 с, распознавание массива и
/// перебор вариантов — секунды. На главном потоке это заблокировало бы приём
/// HTTP-запросов, поэтому каждая задача уходит в отдельный изолят, а сервер
/// лишь ждёт ответ по `SendPort`.
///
/// Протокол: `Isolate.spawn(_isolateEntry, message)`, где message —
/// `{'request': Map, 'sendPort': SendPort}`. Изолят выполняет `runPipeline`,
/// отправляет `{'ok': Map}` либо `{'error': {'code','message','details'}}`
/// и завершается (изолят на задачу — без разделяемого состояния, поэтому
/// результаты детерминированы и не «протекают» между запросами).
library;

import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'errors.dart';
import 'pipeline.dart';

/// Ограничение параллелизма и таймаутов.
class ExecutorLimits {
  /// Максимум одновременно работающих изолятов (по умолчанию — число ядер).
  final int maxConcurrent;

  /// Таймаут одной задачи (лечение «тяжёлого» макета ~16 с, поэтому запас).
  final Duration timeout;

  /// Максимальный размер входного файла в base64 (защита от OOM).
  final int maxBase64Chars;

  ExecutorLimits({
    int? maxConcurrent,
    this.timeout = const Duration(seconds: 180),
    this.maxBase64Chars = 96 * 1024 * 1024,
  }) : maxConcurrent = maxConcurrent == null || maxConcurrent < 1
            ? (Platform.numberOfProcessors < 1 ? 1 : Platform.numberOfProcessors)
            : maxConcurrent;
}

/// Пул изолятов с ограничением параллелизма.
class IsolateExecutor {
  final ExecutorLimits limits;
  int _active = 0;
  final List<Completer<void>> _waiters = [];
  var _closed = false;

  IsolateExecutor({ExecutorLimits? limits})
      : limits = limits ?? ExecutorLimits();

  /// Сколько задач выполняется прямо сейчас (для `/healthz` и метрик).
  int get active => _active;

  /// Число запросов, ожидающих свободный слот.
  int get queued => _waiters.length;

  /// Выполнить задачу в изоляте. Бросает [WorkerError] при ошибке домена,
  /// таймауте или падении изолята.
  Future<Map<String, dynamic>> run(Map<String, dynamic> request) async {
    if (_closed) {
      throw WorkerError.internal('Воркер останавливается: новые задачи '
          'не принимаются.');
    }
    final b64 = request['file_base64'];
    if (b64 is String && b64.length > limits.maxBase64Chars) {
      throw WorkerError.tooLarge(
          'Размер макета в base64 (${b64.length} символов) превышает лимит '
          'воркера (${limits.maxBase64Chars}). Лимит файла — 50 МБ '
          '(PP_MAX_MB): передайте файл через хранилище и file_path.');
    }
    await _acquire();
    try {
      return await _spawnAndRun(request).timeout(
        limits.timeout,
        onTimeout: () => throw WorkerError.timeout(
            'Расчёт занял больше ${limits.timeout.inSeconds} с. Файл слишком '
            'сложный или повреждён — уменьшите геометрию либо увеличьте '
            'PP_DOMAIN_TIMEOUT.'),
      );
    } finally {
      _release();
    }
  }

  void close() {
    _closed = true;
    for (final w in _waiters) {
      if (!w.isCompleted) w.complete();
    }
    _waiters.clear();
  }

  Future<void> _acquire() async {
    if (_active < limits.maxConcurrent) {
      _active++;
      return;
    }
    final c = Completer<void>();
    _waiters.add(c);
    await c.future;
    // Слот уже «передан» вызывающему: _active не менялся.
  }

  void _release() {
    if (_waiters.isNotEmpty) {
      final next = _waiters.removeAt(0);
      if (!next.isCompleted) next.complete();
      return;
    }
    _active--;
  }

  Future<Map<String, dynamic>> _spawnAndRun(
      Map<String, dynamic> request) async {
    final receive = ReceivePort();
    Isolate? isolate;
    try {
      isolate = await Isolate.spawn(_isolateEntry, {
        'request': request,
        'sendPort': receive.sendPort,
      });
      final completer = Completer<Map<String, dynamic>>();
      final subscription = receive.listen((msg) {
        if (msg is! Map) return;
        if (msg['ok'] is Map) {
          if (!completer.isCompleted) {
            completer.complete((msg['ok'] as Map).cast<String, dynamic>());
          }
          return;
        }
        if (msg['error'] is Map) {
          final e = (msg['error'] as Map).cast<String, dynamic>();
          if (!completer.isCompleted) {
            completer.completeError(WorkerError(
              (e['code'] as String?) ?? 'internal',
              (e['message'] as String?) ?? 'Ошибка расчёта в изоляте.',
              httpStatus: (e['httpStatus'] as num?)?.toInt() ?? 500,
              details: (e['details'] as Map?)?.cast<String, dynamic>(),
            ));
          }
        }
      });
      try {
        return await completer.future;
      } finally {
        await subscription.cancel();
      }
    } on IsolateSpawnException catch (e) {
      throw WorkerError.internal(
          'Не удалось запустить изолят для расчёта: ${e.message}');
    } finally {
      isolate?.kill(priority: Isolate.immediate);
      receive.close();
    }
  }
}

/// Точка входа изолята: считает цепочку и отправляет результат обратно.
void _isolateEntry(Map<String, dynamic> message) {
  final sendPort = message['sendPort'] as SendPort;
  final request = (message['request'] as Map).cast<String, dynamic>();
  try {
    final result = runPipeline(normalizeRequestKeys(request));
    sendPort.send({'ok': result.toJson(
      includeRawPaths: request['includeRawPaths'] != false,
    )});
  } on WorkerError catch (e) {
    sendPort.send({
      'error': {
        'code': e.code,
        'message': e.message,
        'httpStatus': e.httpStatus,
        if (e.details != null) 'details': e.details,
      }
    });
  } catch (e, st) {
    sendPort.send({
      'error': {
        'code': 'internal',
        'message': 'Внутренняя ошибка расчёта: $e',
        'httpStatus': 500,
        'details': {'stack': st.toString().split('\n').take(5).toList()},
      }
    });
  }
}
