/// Каталог данных на web: файловой системы у страницы нет (данные живут в
/// localStorage, отчёты скачивает браузер), поэтому путь не нужен.
library;

Future<String?> mobileDataDir() async => null;

Future<String?> mobileReportsDir() async => null;
