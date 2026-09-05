/// Простое JSON-хранилище «каталог + файлы» на desktop и localStorage на web.
///
/// Единый интерфейс для SessionStore/EntitlementStore/ProjectStore/MachineId:
/// desktop — реальные файлы в [directory] (как раньше, layout не меняется),
/// web — ключи localStorage с префиксом из имени каталога (файловой системы в
/// браузере нет).
library;

import 'json_store_io.dart' if (dart.library.html) 'json_store_web.dart'
    as impl;

/// Относительный файл внутри хранилища (например, 'entitlement.json',
/// 'session.json', 'machine_id.txt').
class JsonStore {
  final String directory;
  JsonStore(this.directory);

  Future<String?> read(String rel) => impl.read(directory, rel);
  Future<void> write(String rel, String data) =>
      impl.write(directory, rel, data);
  Future<void> delete(String rel) => impl.delete(directory, rel);
  Future<bool> exists(String rel) => impl.exists(directory, rel);

  /// Имена *.json-файлов без расширения (для списка проектов).
  Future<List<String>> listJsonNames() => impl.listJsonNames(directory);
}
