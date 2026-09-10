/// Окружение на VM/desktop.
library;

import 'dart:io';

const bool isWeb = false;

/// Android/iOS — платформы, где вместо полей пути и встроенного диалога
/// используется системный выбор файла, а данные пишутся в каталог приложения.
bool get isMobile => Platform.isAndroid || Platform.isIOS;

String envOrDefault(String key, String fallback) {
  final v = Platform.environment[key]?.trim();
  return (v != null && v.isNotEmpty) ? v : fallback;
}
