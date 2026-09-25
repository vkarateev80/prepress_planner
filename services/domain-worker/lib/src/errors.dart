/// Ошибки domain-worker: русские сообщения (N-8) и стабильные коды.
///
/// Исключения домена (`ParserException`) и `Issue` из `packages/core`
/// транслируются в [WorkerError] с кодом для HTTP-слоя и для клиента
/// (api/projects). Тексты — только по-русски, как в PRD §8.4.
library;

/// Класс ошибки воркера. Соответствует телу `{"error":{"code","message",
/// "details"}}` (та же схема, что у `services/api`, §12.1 System Design).
class WorkerError implements Exception {
  /// Машиночитаемый код: `bad_request`, `unsupported_format`,
  /// `file_not_found`, `geometry_error`, `remote_error`, `internal`,
  /// `payload_too_large`, `timeout`, `not_found`, `method_not_allowed`.
  final String code;

  /// Русское сообщение (показывается пользователю как есть).
  final String message;

  /// HTTP-статус, которым ошибку отдаёт сервер.
  final int httpStatus;

  /// Дополнительные детали: список `Issue` домена, имя стадии и т.п.
  final Map<String, dynamic>? details;

  const WorkerError(
    this.code,
    this.message, {
    this.httpStatus = 400,
    this.details,
  });

  /// Неверный запрос: структура JSON, типы, отсутствующие ключи.
  factory WorkerError.badRequest(String message,
          {Map<String, dynamic>? details}) =>
      WorkerError('bad_request', message, httpStatus: 400, details: details);

  /// Формат файла не поддержан локально (нужна серверная конвертация).
  factory WorkerError.unsupportedFormat(String message,
          {Map<String, dynamic>? details}) =>
      WorkerError('unsupported_format', message,
          httpStatus: 400, details: details);

  /// Файл недоступен: нет `file_path`, битый base64, ошибка выборки URL.
  factory WorkerError.fileUnavailable(String message,
          {Map<String, dynamic>? details}) =>
      WorkerError('file_not_found', message, httpStatus: 400, details: details);

  /// Геометрия непригодна для расчёта (ошибка `MaterialResult.error`).
  factory WorkerError.geometry(String message,
          {Map<String, dynamic>? details}) =>
      WorkerError('geometry_error', message, httpStatus: 422, details: details);

  /// Тело запроса больше лимита.
  factory WorkerError.tooLarge(String message) =>
      WorkerError('payload_too_large', message, httpStatus: 413);

  /// Превышен таймаут стадии/задачи.
  factory WorkerError.timeout(String message) =>
      WorkerError('timeout', message, httpStatus: 504);

  /// Ошибка изолята/внутренняя ошибка воркера.
  factory WorkerError.internal(String message,
          {Map<String, dynamic>? details}) =>
      WorkerError('internal', message, httpStatus: 500, details: details);

  /// JSON-представление для тела ответа.
  Map<String, dynamic> toJson() => {
        'error': {
          'code': code,
          'message': message,
          if (details != null && details!.isNotEmpty) 'details': details,
        }
      };

  @override
  String toString() => 'WorkerError($code, $httpStatus): $message';
}
