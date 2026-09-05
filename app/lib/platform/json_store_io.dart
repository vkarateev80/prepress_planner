/// JSON-хранилище на VM/desktop: реальные файлы в каталоге.
library;

import 'dart:io';

Future<String?> read(String directory, String rel) async {
  final f = File(_path(directory, rel));
  if (!await f.exists()) return null;
  try {
    return await f.readAsString();
  } catch (_) {
    return null;
  }
}

Future<void> write(String directory, String rel, String data) async {
  final f = File(_path(directory, rel));
  await f.parent.create(recursive: true);
  await f.writeAsString(data, flush: true);
}

Future<void> delete(String directory, String rel) async {
  final f = File(_path(directory, rel));
  if (await f.exists()) {
    try {
      await f.delete();
    } catch (_) {}
  }
}

Future<bool> exists(String directory, String rel) async =>
    File(_path(directory, rel)).exists();

Future<List<String>> listJsonNames(String directory) async {
  final d = Directory(directory == '' ? '.' : directory);
  if (!await d.exists()) return [];
  return d
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.json'))
      .map((f) => f.path
          .split(RegExp(r'[/\\]'))
          .last
          .replaceAll(RegExp(r'\.json$'), ''))
      .toList();
}

String _path(String directory, String rel) {
  final base = directory == '' ? '.' : directory;
  return '$base/$rel';
}
