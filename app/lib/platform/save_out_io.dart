/// Сохранение отчёта на VM: запись файла в каталог [dirName]; на Android/iOS
/// каталог из UI недоступен для записи, поэтому отчёт кладётся в каталог
/// приложения (reports) — путь возвращается для статуса/лога.
library;

import 'dart:io';
import 'dart:typed_data';

import 'app_dirs.dart';

Future<String> saveReport(String dirName, String fileName, Uint8List bytes) async {
  // На desktop — как раньше: каталог из UI (относительный путь рядом с
  // приложением). На мобильных подменяем его каталогом приложения.
  final mobile = await mobileReportsDir();
  final dir = mobile ?? (dirName.isEmpty ? '.' : dirName);
  final d = Directory(dir);
  if (!d.existsSync()) {
    d.createSync(recursive: true);
  }
  final f = File('$dir/$fileName');
  await f.writeAsBytes(bytes, flush: true);
  return f.path;
}
