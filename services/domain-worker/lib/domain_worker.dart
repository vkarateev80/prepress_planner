/// Публичный барель воркера домена (ADR-2).
///
/// Точка входа сервиса — `bin/domain_worker.dart`; тесты и инструменты
/// используют этот барель (относительный импорт, как в `packages/core`).
library;

export 'src/errors.dart';
export 'src/params.dart';
export 'src/state.dart';
export 'src/pipeline.dart';
export 'src/isolate_executor.dart';
export 'src/request.dart';
export 'src/server.dart';
