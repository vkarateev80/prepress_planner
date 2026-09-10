/// Каталог данных на VM: на Android/iOS — каталог приложения (только он доступен
/// для записи), на desktop — null (там работает текущий каталог процесса).
library;

import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Каталог документов приложения + подкаталог [sub]; создаётся сразу, чтобы
/// первая же запись не падала на отсутствующем каталоге.
Future<String?> _appSubdir(String sub) async {
  final base = await getApplicationDocumentsDirectory();
  final dir = Directory('${base.path}/$sub');
  if (!dir.existsSync()) {
    await dir.create(recursive: true);
  }
  return dir.path;
}

Future<String?> mobileDataDir() async {
  // Desktop (Windows/Linux/macOS): плагин не нужен — пути остаются прежними.
  if (!Platform.isAndroid && !Platform.isIOS) return null;
  try {
    return await _appSubdir('PrepressPlanner');
  } catch (_) {
    // Каталог недоступен (например, плагин не зарегистрирован): приложение
    // стартует по относительным путям, а об ошибке записи сообщит хранилище —
    // это лучше, чем падение на запуске.
    return null;
  }
}

Future<String?> mobileReportsDir() async {
  if (!Platform.isAndroid && !Platform.isIOS) return null;
  try {
    return await _appSubdir('PrepressPlanner/reports');
  } catch (_) {
    return null;
  }
}
