/// Файловые операции: desktop читает по путям, web — браузерный picker и
/// download, Android/iOS — системный выбор файла и запись в каталог приложения.
/// Общий API один; реализации условные.
library;

import 'dart:typed_data';

import 'files_io.dart' if (dart.library.html) 'files_web.dart' as impl;

/// Элемент каталога (для браузера папок на desktop).
class FsEntry {
  final String path;
  final String name;
  final bool isDir;
  const FsEntry(this.path, this.name, this.isDir);
}

/// Выбранный пользователем файл (имя + байты).
class FilePick {
  final String name;
  final Uint8List bytes;
  const FilePick(this.name, this.bytes);
}

/// Каталог по умолчанию (домашний) для старта браузера папок.
String get homeDir => impl.homeDir;

/// Список содержимого каталога (desktop; на web не используется).
Future<List<FsEntry>> listDir(String path) => impl.listDir(path);

Future<bool> exists(String path) => impl.exists(path);

bool isDir(String path) => impl.isDir(path);

/// Прочитать файл целиком по пути (desktop).
Future<Uint8List> readBytes(String path) => impl.readBytes(path);

/// Диалог выбора одного файла (web: <input type=file>; Android/iOS: системный
/// picker file_selector); на desktop возвращает null — там выбор идёт через
/// браузер папок + [readBytes].
Future<FilePick?> pickSingleFile() => impl.pickSingleFile();

/// Сохранить/скачать файл для пользователя (web: anchor download; desktop:
/// пишет в домашний каталог; Android/iOS: в каталог приложения) и возвращает
/// путь/имя записанного файла.
Future<String> saveFileForUser(String fileName, Uint8List bytes) =>
    impl.saveFileForUser(fileName, bytes);
