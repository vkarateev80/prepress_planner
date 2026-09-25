/// Управление сервером конвертации: проверка доступности (probe) и запуск
/// ЛОКАЛЬНОГО uvicorn (только desktop; в браузере процесса нет).
///
/// Реализация запуска — условный лаунчер: [server_launch_io] (dart:io,
/// дочерний процесс uvicorn) либо [server_launch_web] (заглушка с русским
/// сообщением). Сам класс чистый: dart:io сюда не попадает.
library;

import '../../platform/env.dart';
import '../../platform/http.dart';
import 'server_launch_io.dart' if (dart.library.html) 'server_launch_web.dart'
    as launch;

/// Управление локальным сервером конвертации (uvicorn: services/converter).
class ConverterServer {
  /// Адрес сервера, доступность которого проверяется.
  final String baseUrl;

  ConverterServer({String? baseUrl}) : baseUrl = baseUrl ?? defaultBaseUrl();

  /// Адрес по умолчанию: env `PP_CONVERTER_URL` (desktop/VM), на web — тот же
  /// origin (ADR-1/ADR-6). Зашитый IP удалён: пусто = относительные URL.
  /// Для desktop дефолт остаётся локальным сервером разработки (8120).
  static String defaultBaseUrl() =>
      envOrDefault('PP_CONVERTER_URL', isWeb ? '' : _localDefault);

  /// Локальный адрес сервера разработки (desktop): `converter_server` умеет
  /// поднимать его сам, если он не отвечает.
  static const String _localDefault = 'http://127.0.0.1:8120';

  /// Локальный ли адрес (только для такого можно поднять uvicorn на этом ПК;
  /// в браузере локальный запуск невозможен в принципе).
  static bool isLocal(String baseUrl) {
    if (baseUrl.isEmpty) return false; // same-origin: процессом браузер не управляет
    final uri = Uri.tryParse(baseUrl);
    if (uri == null || !uri.hasScheme) return false;
    final host = uri.host;
    return host == '127.0.0.1' ||
        host == 'localhost' ||
        host == '::1' ||
        host == '0.0.0.0';
  }

  /// Сервер отвечает по HTTP (любой статус — значит процесс жив).
  Future<bool> probe() async {
    final base = baseUrl.endsWith('/')
        ? baseUrl.substring(0, baseUrl.length - 1)
        : baseUrl;
    try {
      final resp = await httpRawGet('$base/healthz',
          timeout: const Duration(seconds: 3));
      return resp.status > 0;
    } catch (_) {
      return false;
    }
  }

  /// Проверить сервер и, если он не запущен, поднять локальный uvicorn
  /// (только desktop и только для локального адреса).
  /// Возвращает null при успехе (сервер уже работал или запущен), иначе —
  /// текст ошибки для UI.
  Future<String?> ensureRunning() async {
    if (await probe()) return null;

    final uri = Uri.tryParse(baseUrl);
    final host = (uri != null && uri.hasScheme)
        ? (uri.host.isEmpty ? '127.0.0.1' : uri.host)
        : '127.0.0.1';
    if (!isLocal(baseUrl)) {
      return 'Сервер $host недоступен, а это удалённый адрес — локально '
          'запустить его нельзя. Проверьте адрес или доступность сервера.';
    }
    return launch.ensureLocalConverter(baseUrl);
  }

  /// Поиск venv-python в репозитории (desktop; на web — null).
  static String? findPythonAbove(String start) =>
      launch.findPythonAbove(start);
}
