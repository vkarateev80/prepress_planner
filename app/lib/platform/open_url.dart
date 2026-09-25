/// Открыть URL во внешнем браузере.
///
/// Реализация подставляется условным импортом: `open_url_web.dart` в браузере
/// (dart:html window.open), `open_url_io.dart` на VM/desktop (dart:io Process).
library;

import 'open_url_io.dart' if (dart.library.html) 'open_url_web.dart' as impl;

/// Открыть [url] во внешнем приложении (новая вкладка браузера).
void openUrlExternal(String url) => impl.openUrlExternal(url);
