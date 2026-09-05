/// Окружение на VM/desktop.
library;

import 'dart:io';

const bool isWeb = false;

String envOrDefault(String key, String fallback) {
  final v = Platform.environment[key]?.trim();
  return (v != null && v.isNotEmpty) ? v : fallback;
}
