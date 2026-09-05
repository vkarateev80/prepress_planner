/// Сохранение отчёта на VM/desktop: запись файла в каталог [dirName].
library;

import 'dart:io';
import 'dart:typed_data';

Future<String> saveReport(String dirName, String fileName, Uint8List bytes) async {
  final dir = dirName.isEmpty ? '.' : dirName;
  final d = Directory(dir);
  if (!d.existsSync()) {
    d.createSync(recursive: true);
  }
  final f = File('$dir/$fileName');
  await f.writeAsBytes(bytes, flush: true);
  return f.path;
}
