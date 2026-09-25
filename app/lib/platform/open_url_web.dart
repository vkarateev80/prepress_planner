/// Открытие URL в браузере (web-сборка).
library;

// ignore: deprecated_member_use -- dart:html остаётся: pub.dev недоступен, package:web не установить
import 'dart:html' as html;

void openUrlExternal(String url) {
  html.window.open(url, '_blank');
}
