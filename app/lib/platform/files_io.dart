/// Файловые операции на VM/desktop: реальная файловая система.
/// На Android/iOS дополнительно доступен системный выбор файла (file_selector)
/// и запись в каталог приложения — см. ветки [isMobile].
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart' as file_selector;

import 'app_dirs.dart';
import 'env.dart';
import 'files.dart' show FilePick, FsEntry;

/// Домашний каталог пользователя — стартовая точка браузера папок на desktop
/// (на мобильных этот диалог не используется: там системный выбор файла).
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

/// Форматы, которые принимает picker. На Android фильтр строится по расширениям
/// и mime-типам (закрытые форматы вроде .cdr/.ai DocumentsProvider часто отдаёт
/// как application/octet-stream — без него они были бы скрыты в диалоге);
/// на iOS расширения не поддерживаются вовсе, нужны UTI, а системных UTI для
/// CDR/DXF нет — их закрывает корневой public.data (файл всё равно проверяется
/// приложением при разборе).
const _vectorTypes = file_selector.XTypeGroup(
  label: 'Векторные файлы',
  extensions: ['ai', 'cdr', 'eps', 'svg', 'dxf', 'pdf'],
  mimeTypes: [
    'application/pdf',
    'image/svg+xml',
    'application/postscript', // .eps
    'application/illustrator', // .ai
    'application/vnd.corel-draw', // .cdr
    'image/vnd.dxf', // .dxf
    'application/octet-stream', // незнакомые системе расширения
  ],
  uniformTypeIdentifiers: [
    'com.adobe.pdf',
    'public.svg-image',
    'com.adobe.eps',
    'com.adobe.illustrator.ai-image',
    'public.data', // «любой файл»: UTI для CDR/DXF в системе не объявлены
  ],
);

/// На Android/iOS — системный выбор файла (path_provider/file_selector: у
/// мобильных сборок нет ни браузера папок, ни поля пути); на desktop возвращает
/// null: там файл выбирается встроенным диалогом UI + [readBytes].
Future<FilePick?> pickSingleFile() async {
  if (!isMobile) return null;
  final picked = await file_selector.openFile(
      acceptedTypeGroups: const [_vectorTypes]);
  if (picked == null) return null;
  final bytes = await picked.readAsBytes();
  // Имя (а по нему определяется формат) плагин сохраняет при копировании
  // выбранного файла во временный каталог приложения.
  return FilePick(picked.name, bytes);
}

/// Сохранение файла для пользователя: на Android/iOS — в каталог приложения
/// (внешнего Downloads и домашнего каталога там нет), на desktop — в ~/Downloads.
Future<String> saveFileForUser(String fileName, Uint8List bytes) async {
  final mobile = await mobileReportsDir();
  final dir = Directory(mobile ?? '${homeDir}/Downloads');
  await dir.create(recursive: true);
  final f = File('${dir.path}/$fileName');
  await f.writeAsBytes(bytes, flush: true);
  return f.path;
}
