/// Открытие URL в браузере (web-сборка).
library;

// ignore: deprecated_member_use -- dart:html остаётся: pub.dev недоступен, package:web не установить
import 'dart:html' as html;

/// Окно, открытое синхронно в рамках жеста клика (about:blank);
/// после checkout получает реальный URL — иначе popup-блокировка.
html.WindowBase? _grabbed;

bool grabPopupWindow() {
  try {
    _grabbed = html.window.open('about:blank', '_blank');
  } catch (_) {
    _grabbed = null;
  }
  return _grabbed != null;
}

void releasePopupWindow() {
  final w = _grabbed;
  _grabbed = null;
  try {
    if (w is html.Window) w.close();
  } catch (_) {}
}

void openUrlExternal(String url) {
  final w = _grabbed;
  _grabbed = null;
  if (w != null) {
    // Навигация уже открытого окна не считается popup-блокировкой.
    try {
      w.location.href = url;
      return;
    } catch (_) {
      // Падаем на обычное открытие ниже.
    }
  }
  html.window.open(url, '_blank');
}
