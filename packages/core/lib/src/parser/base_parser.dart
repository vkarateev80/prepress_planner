import 'dart:typed_data';

import '../model/cam_path.dart';

/// Базовый парсер векторных форматов: байты -> список полилиний (мм, Y↑).
/// Чтение файлов (dart:io) — вне ядра: смотри io-фасад пакета (lib/io.dart).
abstract class BaseParser {
  List<CamPath> parseBytes(Uint8List bytes);
}
