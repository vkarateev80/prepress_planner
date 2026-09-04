/// Журнал событий приложения: единая in-memory лента, которую показывает
/// окно «Журнал событий» (см. widgets/log_window.dart) и из которой ошибки
/// можно скопировать целиком (Clipboard), не вылавливая их из консоли.
library;

import 'package:flutter/foundation.dart';

enum LogLevel { info, warning, error }

class LogEntry {
  final DateTime time;
  final LogLevel level;
  final String source;
  final String message;

  const LogEntry({
    required this.time,
    required this.level,
    required this.source,
    required this.message,
  });
}

/// Синглтон-лента. Никаких внешних пакетов: только ChangeNotifier + память.
/// Каждая запись пишется с временем/уровнем/источником; лента ограничена
/// сверху (самые старые записи отбрасываются).
class AppLog extends ChangeNotifier {
  AppLog._();

  static final AppLog instance = AppLog._();

  static const int _maxEntries = 2000;
  static const int _maxMessageLen = 20000;

  final List<LogEntry> _entries = [];

  /// Копия ленты (самая свежая запись — последняя).
  List<LogEntry> get entries => List.unmodifiable(_entries);

  int get errorCount =>
      _entries.where((e) => e.level == LogLevel.error).length;

  void clear() {
    if (_entries.isEmpty) return;
    _entries.clear();
    notifyListeners();
  }

  void info(String source, String message) =>
      record(source, message, level: LogLevel.info);

  void warn(String source, String message) =>
      record(source, message, level: LogLevel.warning);

  void error(String source, String message) =>
      record(source, message, level: LogLevel.error);

  /// Единая точка записи: [source] — модуль (Геометрия, Отчёты, Flutter…).
  void record(String source, String message,
      {LogLevel level = LogLevel.info}) {
    final text = message.length > _maxMessageLen
        ? '${message.substring(0, _maxMessageLen)}\n…(обрезано)'
        : message;
    _entries.add(LogEntry(
        time: DateTime.now(), level: level, source: source, message: text));
    if (_entries.length > _maxEntries) {
      _entries.removeRange(0, _entries.length - _maxEntries);
    }
    notifyListeners();
  }

  /// Полный текст ленты для копирования в буфер обмена.
  String get fullText => _entries.map(format).join('\n');

  /// Время записи как `[ЧЧ:ММ:СС]` — для цветной разбивки строк в окне.
  static String stamp(LogEntry e) {
    String two(int v) => v.toString().padLeft(2, '0');
    final t = e.time;
    return '[${two(t.hour)}:${two(t.minute)}:${two(t.second)}]';
  }

  /// Буква уровня: I / W / E.
  static String levelLetter(LogLevel level) => switch (level) {
        LogLevel.info => 'I',
        LogLevel.warning => 'W',
        LogLevel.error => 'E',
      };

  static String format(LogEntry e) =>
      '${stamp(e)} [${levelLetter(e.level)}] [${e.source}] ${e.message}';

  /// Глобальный перехват необработанных ошибок Flutter/Dart, чтобы
  /// падения тоже попадали в журнал и их можно было скопировать.
  void installGlobalHandlers() {
    if (_globalInstalled) return;
    _globalInstalled = true;

    final previous = FlutterError.onError;
    FlutterError.onError = (FlutterErrorDetails details) {
      error('Flutter',
          '${details.exceptionAsString()}\n${_compactStack(details.stack)}');
      previous?.call(details);
    };

    final platform = PlatformDispatcher.instance;
    final previousPlatform = platform.onError;
    platform.onError = (Object err, StackTrace stack) {
      error('Platform', '$err\n${_compactStack(stack)}');
      previousPlatform?.call(err, stack);
      return false;
    };
  }

  static bool _globalInstalled = false;

  /// Стек ужимается до 40 строк — достаточно для диагностики и копирования,
  /// не заваливая ленту километровыми трейсами.
  static String _compactStack(StackTrace? stack) {
    final s = stack?.toString() ?? '';
    final lines = s
        .split('\n')
        .where((l) => l.trim().isNotEmpty)
        .take(40)
        .toList();
    return lines.join('\n');
  }
}
