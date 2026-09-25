/// Файловые операции на web: picker (<input type=file>) и download (anchor).
/// Путей/файловой системы в браузере нет.
library;

import 'dart:async';
// ignore: deprecated_member_use -- dart:html остаётся: pub.dev недоступен, package:web не установить
import 'dart:html' as html;
import 'dart:typed_data';

import 'files.dart' show FilePick, FsEntry;

String get homeDir => '';

Future<List<FsEntry>> listDir(String path) async => const [];

Future<bool> exists(String path) async => false;

bool isDir(String path) => false;

Future<Uint8List> readBytes(String path) async => Uint8List(0);

Future<FilePick?> pickSingleFile() async {
  final completer = Completer<FilePick?>();
  final input = html.InputElement()
    ..type = 'file'
    ..accept = '.ai,.cdr,.eps,.svg,.dxf,.pdf';
  input.onChange.listen((_) {
    final files = input.files;
    final f = (files == null || files.isEmpty) ? null : files[0];
    if (f == null) {
      completer.complete(null);
      return;
    }
    final reader = html.FileReader();
    reader.onLoad.listen((_) {
      final result = reader.result;
      if (result is ByteBuffer) {
        completer.complete(
            FilePick(f.name, result.asUint8List(0, result.lengthInBytes)));
      } else {
        completer.complete(null);
      }
    });
    reader.onError.listen((_) => completer.complete(null));
    reader.readAsArrayBuffer(f);
  });
  input.click();
  return completer.future;
}

Future<String> saveFileForUser(String fileName, Uint8List bytes) async {
  final blob = html.Blob([bytes]);
  final url = html.Url.createObjectUrlFromBlob(blob);
  try {
    final a = html.AnchorElement(href: url)..download = fileName;
    html.document.body?.append(a);
    a.click();
    a.remove();
  } finally {
    html.Url.revokeObjectUrl(url);
  }
  return fileName;
}
