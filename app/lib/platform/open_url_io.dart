/// Открытие URL на VM/desktop через системный обработчик.
library;

import 'dart:io';

void openUrlExternal(String url) {
  final String program;
  final List<String> args;
  if (Platform.isMacOS) {
    program = 'open';
    args = [url];
  } else if (Platform.isWindows) {
    program = 'cmd';
    args = ['/c', 'start', '', url];
  } else {
    program = 'xdg-open';
    args = [url];
  }
  // detached: браузер открывается отдельным процессом, ошибки не критичны.
  Process.start(program, args, mode: ProcessStartMode.detached)
      .then((_) {})
      .catchError((_) {});
}
