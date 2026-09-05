/// Сохранение отчёта: desktop пишет файл в указанный каталог, web скачивает
/// через браузер. Возвращает строку для статуса/лога: на desktop — полный
/// путь записанного файла, на web — имя скачанного файла.
library;

import 'dart:typed_data';

import 'save_out_io.dart' if (dart.library.html) 'save_out_web.dart' as impl;

Future<String> saveReport(String dirName, String fileName, Uint8List bytes) =>
    impl.saveReport(dirName, fileName, bytes);
