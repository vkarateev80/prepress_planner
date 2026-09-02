import '../model/cam_path.dart';

/// Базовый парсер векторных форматов: файл -> список полилиний (мм, Y↑).
abstract class BaseParser {
  List<CamPath> parse(String filePath);
}
