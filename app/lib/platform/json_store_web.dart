/// JSON-хранилище на web: localStorage с префиксом из имени каталога.
///
/// Файловой системы в браузере нет — данные живут в localStorage браузера.
/// Префикс `pp.<directory>.` не даёт пересечься разным хранилищам; список
/// проектов получаем сканированием ключей префикса.
library;

// ignore: deprecated_member_use -- dart:html остаётся: pub.dev недоступен, package:web не установить
import 'dart:html' as html;

const _kNamespace = 'pp_prepress_planner';

String _key(String directory, String rel) {
  final dir = (directory == '' || directory == '.') ? 'root' : directory;
  return '$_kNamespace.$dir/$rel';
}

String _dirPrefix(String directory) {
  final dir = (directory == '' || directory == '.') ? 'root' : directory;
  return '$_kNamespace.$dir/';
}

Future<String?> read(String directory, String rel) async =>
    html.window.localStorage[_key(directory, rel)];

Future<void> write(String directory, String rel, String data) async {
  html.window.localStorage[_key(directory, rel)] = data;
}

Future<void> delete(String directory, String rel) async {
  html.window.localStorage.remove(_key(directory, rel));
}

Future<bool> exists(String directory, String rel) async =>
    html.window.localStorage.containsKey(_key(directory, rel));

Future<List<String>> listJsonNames(String directory) async {
  final prefix = _dirPrefix(directory);
  final out = <String>[];
  for (final k in html.window.localStorage.keys) {
    if (!k.startsWith(prefix)) continue;
    var rel = k.substring(prefix.length);
    if (rel.endsWith('.json')) {
      rel = rel.substring(0, rel.length - 5);
      out.add(rel);
    }
  }
  return out;
}
