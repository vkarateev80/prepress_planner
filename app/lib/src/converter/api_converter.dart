/// Конвертер SaaS-пути закрытых форматов (ADR-7).
///
/// Вместо прямого `POST /convert` в `services/converter` файл уходит в
/// `services/api`: `POST /api/projects/{id}/files` (multipart, `convert=svg`,
/// синхронно) → `GET /api/files/{id}/content?format=svg` → байты SVG.
///
/// Если сессии нет (анонимный режим) или проект ещё не в облаке, запрос
/// уходит в [fallback] — прежний прямой клиент `services/converter`
/// (`/convert` через edge nginx), поведение не меняется.
library;

import 'dart:typed_data';

import '../../license/account_client.dart' show ApiException;
import '../projects/cloud_projects.dart';
import 'converter_api.dart';

class ApiConverter implements Converter {
  final ProjectsApi api;
  final Converter fallback;
  final Future<String?> Function() tokenProvider;
  final Future<String?> Function() projectIdProvider;

  /// `file_id` загруженного **оригинала** последнего успешного вызова
  /// [convertToSvg] (parent-файл в `services/api`, §12.5). null — конвертация
  /// шла мимо api (фолбэк) или завершилась ошибкой. Читается сразу после
  /// `convertToSvg` (UI однопоточный).
  String? lastOriginalFileId;

  ApiConverter({
    required this.api,
    required this.tokenProvider,
    required this.projectIdProvider,
    Converter? fallback,
  }) : fallback = fallback ?? ConverterApi();

  @override
  String get baseUrl => api.baseUrl;

  @override
  Future<Uint8List> convertToSvg({
    required String fileName,
    required Uint8List bytes,
  }) async {
    lastOriginalFileId = null;
    final token = await tokenProvider();
    final projectId = await projectIdProvider();
    if (token == null || token.isEmpty || projectId == null) {
      return fallback.convertToSvg(fileName: fileName, bytes: bytes);
    }
    try {
      final j = await api.uploadAndConvert(
          token, projectId, fileName, bytes,
          target: 'svg');
      final convertedId = j['converted_file_id'] as String?;
      if (convertedId == null || convertedId.isEmpty) {
        throw const ConverterException(
            'Сервер не вернул сконвертированный файл.');
      }
      // Оригинал уже в облаке (multipart той же загрузки) — запомним id.
      lastOriginalFileId = (j['parent_file_id'] ?? j['file_id']) as String?;
      return await api.fileContent(token, convertedId, format: 'svg');
    } on ApiException catch (e) {
      throw ConverterException(e.message);
    }
  }
}
