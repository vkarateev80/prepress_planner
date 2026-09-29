/// Открытие URL во внешнем браузере.
///
/// Реализация подставляется условным импортом: `open_url_web.dart` в браузере
/// (dart:html window.open), `open_url_io.dart` на VM/desktop (dart:io Process).
library;

import 'open_url_io.dart' if (dart.library.html) 'open_url_web.dart' as impl;

/// Открыть [url] во внешнем приложении (новая вкладка браузера).
///
/// На web, если окно предзахвачено [grabPopupWindow], навигирует именно его —
/// иначе Safari/Chrome блокируют поздний window.open (после await).
void openUrlExternal(String url) => impl.openUrlExternal(url);

/// Синхронно открыть пустое окно в рамках пользовательского жеста клика.
/// На web возвращает true, если окно открыто; на desktop — всегда false
/// (там popup-блокировки нет). Вызывать ДО первого await.
bool grabPopupWindow() => impl.grabPopupWindow();

/// Закрыть предзахваченное окно (например, если checkout не удался).
void releasePopupWindow() => impl.releasePopupWindow();
