/// Каталог данных приложения: на Android/iOS рабочий каталог процесса недоступен
/// для записи, поэтому состояние/проекты/отчёты живут в каталоге приложения
/// (path_provider). На desktop/web возвращается null — там работают прежние
/// относительные пути, и поведение сборок не меняется.
library;

import 'app_dirs_io.dart' if (dart.library.html) 'app_dirs_web.dart' as impl;

/// Каталог данных приложения на Android/iOS, иначе null (desktop/web).
Future<String?> mobileDataDir() => impl.mobileDataDir();

/// Каталог отчётов внутри каталога данных приложения (Android/iOS), иначе null.
/// На мобильных файл нельзя положить «рядом с приложением» или в Downloads,
/// поэтому отчёты складываются в подкаталог reports каталога приложения.
Future<String?> mobileReportsDir() => impl.mobileReportsDir();
