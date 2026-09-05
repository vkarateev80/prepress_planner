/// Сохранение отчёта на web: скачивание файла браузером (каталог не важен).
library;

import 'dart:typed_data';

import 'files.dart';

Future<String> saveReport(String dirName, String fileName, Uint8List bytes) =>
    saveFileForUser(fileName, bytes);
