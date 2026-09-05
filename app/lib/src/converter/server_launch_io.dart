/// Запуск локального сервера конвертации на desktop (dart:io).
///
/// services/converter (FastAPI, uvicorn): поднимается как дочерний процесс:
/// venv-python из cam_pipeline + uvicorn с рабочей директорией
/// services/converter. Вывод uvicorn читается слушателями (иначе дочерний
/// процесс заблокируется на заполненном pipe); хвост вывода хранится в
/// памяти и показывается в сообщении об ошибке, если сервер не поднялся.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../../platform/http.dart';

/// Поднять локальный uvicorn для [baseUrl] (локальный адрес!). null = успех,
/// иначе текст ошибки.
Future<String?> ensureLocalConverter(String baseUrl) async {
  final uri = Uri.parse(baseUrl);
  final host = uri.hasScheme
      ? (uri.host.isEmpty ? '127.0.0.1' : uri.host)
      : '127.0.0.1';
  final port = uri.hasPort ? uri.port : 8120;

  final python = _findPython();
  if (python == null) {
    return 'Не найден python (cam_pipeline\\venv\\Scripts\\python.exe). '
        'Запустите сервер вручную: uvicorn converter_app.main:app --port 8120 '
        'либо задайте env PP_CONVERTER_PYTHON.';
  }
  final serviceDir = _findServiceDir();
  if (serviceDir == null) {
    return 'Не найден каталог services/converter рядом с приложением. '
        'Запустите сервер вручную либо задайте env PP_CONVERTER_PYTHON.';
  }

  Process proc;
  try {
    proc = await Process.start(
      python,
      [
        '-m', 'uvicorn', 'converter_app.main:app',
        '--host', host,
        '--port', '$port',
      ],
      workingDirectory: serviceDir,
      runInShell: false,
    );
  } catch (e) {
    return 'Не удалось запустить сервер: $e';
  }

  // Вывод дочернего процесса обязательно читаем (иначе он заблокируется на
  // заполненном pipe) и держим хвост для сообщения об ошибке.
  final tail = _OutputTail();
  proc.stdout
      .transform(utf8.decoder)
      .listen(tail.add, onError: (Object _) {});
  proc.stderr
      .transform(utf8.decoder)
      .listen(tail.add, onError: (Object _) {});

  // Ждём, пока сервер начнёт отвечать (обычно 1–3 с), но не вечно.
  final deadline = DateTime.now().add(const Duration(seconds: 20));
  var up = false;
  while (DateTime.now().isBefore(deadline) && !up) {
    up = await _probe(host, port);
    if (!up) await Future<void>.delayed(const Duration(milliseconds: 300));
  }
  if (up) return null;

  // Не поднялся: убиваем и показываем хвост вывода для диагностики.
  try {
    proc.kill();
  } catch (_) {}
  return 'Сервер не запустился за 20 с.'
      '${tail.isEmpty ? '' : '\n${tail.text}'}';
}

Future<bool> _probe(String host, int port) async {
  try {
    final resp = await httpRawGet('http://$host:$port/healthz',
        timeout: const Duration(seconds: 3));
    return resp.status > 0;
  } catch (_) {
    return false;
  }
}

/// Поиск venv-python в репозитории: поднимаемся от [start] вверх,
/// пока не встретим каталог с cam_pipeline\venv и services\converter.
String? findPythonAbove(String start) {
  var dir = Directory(start);
  for (var i = 0; i < 12; i++) {
    final py = '${dir.path}/cam_pipeline/venv/Scripts/python.exe';
    final svc = '${dir.path}/services/converter/converter_app/main.py';
    if (File(py).existsSync() && File(svc).existsSync()) return py;
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  return null;
}

String? _findPython() {
  // Явное указание имеет приоритет.
  final env = Platform.environment['PP_CONVERTER_PYTHON']?.trim();
  if (env != null && env.isNotEmpty && File(env).existsSync()) return env;
  // От exe приложения (build\windows\...\Release) и от текущего каталога.
  final candidates = <String>[
    if (Platform.resolvedExecutable.isNotEmpty)
      File(Platform.resolvedExecutable).parent.path,
    Directory.current.path,
  ];
  for (final c in candidates) {
    final found = findPythonAbove(c);
    if (found != null) return found;
  }
  return null;
}

String? _findServiceDir() {
  final python = _findPython();
  if (python == null) return null;
  // venv-путь cam_pipeline/venv/Scripts/python.exe → каталог репозитория.
  final idx = python.toLowerCase().indexOf('cam_pipeline');
  if (idx < 0) return null;
  final repo = python.substring(0, idx);
  final dir = Directory('$repo/services/converter');
  return dir.existsSync() ? dir.path : null;
}

/// Хвост вывода процесса (для сообщения об ошибке запуска).
class _OutputTail {
  static const _max = 4000;
  final StringBuffer _buf = StringBuffer();
  int _len = 0;

  void add(String chunk) {
    if (chunk.isEmpty) return;
    _buf.write(chunk);
    _len += chunk.length;
    if (_len > _max) {
      final s = _buf.toString();
      final cut = s.substring(s.length - _max);
      _buf
        ..clear()
        ..write(cut);
      _len = _max;
    }
  }

  bool get isEmpty => _len == 0;
  String get text => _buf.toString();
}
