/// Файловые операции на VM/desktop: реальная файловая система.
library;

import 'dart:io';
import 'dart:typed_data';

import 'files.dart' show FilePick, FsEntry;

String get homeDir {
  try {
    return Platform.environment['USERPROFILE'] ?? Directory.current.path;
  } catch (_) {
    return Directory.current.path;
  }
}

Future<List<FsEntry>> listDir(String path) async {
  final d = Directory(path);
  try {
    return d
        .listSync()
        .whereType<FileSystemEntity>()
        .map((e) => FsEntry(
            e.path,
            e.path.split(RegExp(r'[/\\]')).last,
            e is Directory))
        .toList();
  } catch (_) {
    return const [];
  }
}

Future<bool> exists(String path) async => File(path).exists();

bool isDir(String path) {
  try {
    return Directory(path).existsSync();
  } catch (_) {
    return false;
  }
}

Future<Uint8List> readBytes(String path) async =>
    Uint8List.fromList(await File(path).readAsBytes());

/// На desktop файл выбирается браузером папок в UI — picker не используется.
Future<FilePick?> pickSingleFile() async => null;

Future<String> saveFileForUser(String fileName, Uint8List bytes) async {
  final dir = Directory('${homeDir}/Downloads');
  await dir.create(recursive: true);
  final f = File('${dir.path}/$fileName');
  await f.writeAsBytes(bytes, flush: true);
  return f.path;
}
