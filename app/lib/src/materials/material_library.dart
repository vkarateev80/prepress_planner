/// Библиотека сортамента приложения.
///
/// Хранит ПОЛЬЗОВАТЕЛЬСКИЕ материалы (добавленные на экране ТЭО) отдельно от
/// встроенного каталога-примера и текущий выбранный материал ([selectedId]).
/// Персистентность: `JsonStore` — desktop: файл `<state>/materials.json`;
/// web: localStorage. Спецификация материала (поля):
///   name        — название/описание (например, «Плёнка ПЭТ 50 мкм»);
///   pricePerM2  — цена за квадратный метр, ₽/м²;
///   minOrderM2  — минимальный заказ, м² (необязательно).
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:prepress_core/prepress_core.dart';

import '../../platform/json_store.dart';

class MaterialLibrary extends ChangeNotifier {
  MaterialLibrary(String directory)
      : _store = JsonStore(directory);

  static const String _file = 'materials.json';

  final JsonStore _store;
  final List<AssortmentItem> _custom = [];
  String? _selectedId;
  bool _loaded = false;
  String? _error;

  /// Встроенный каталог-пример (не редактируется, всегда в начале списка).
  List<AssortmentItem> get defaults =>
      PriceCatalog.defaults().assortment;

  /// Пользовательские материалы (в порядке добавления).
  List<AssortmentItem> get customs => List.unmodifiable(_custom);

  /// Полный список для выпадающего списка: примеры + пользовательские.
  List<AssortmentItem> get all => [...defaults, ..._custom];

  bool get loaded => _loaded;
  String? get error => _error;

  /// id выбранного материала (null — выбран материал по умолчанию).
  String? get selectedId => _selectedId;

  /// Материал по [id] или первый из каталога-примера, если id не задан/не найден.
  AssortmentItem resolve(String? id) {
    if (id != null) {
      for (final a in all) {
        if (a.id == id) return a;
      }
    }
    return defaults.first;
  }

  Future<void> load() async {
    try {
      final raw = await _store.read(_file);
      if (raw != null && raw.isNotEmpty) {
        final j = jsonDecode(raw);
        if (j is Map) {
          final items = j['items'];
          if (items is List) {
            _custom
              ..clear()
              ..addAll(_parseItems(items));
          }
          final sel = j['selected'];
          if (sel is String && sel.isNotEmpty) _selectedId = sel;
        }
      }
      _error = null;
    } catch (e) {
      _error = 'Не удалось прочитать материалы: $e';
    } finally {
      _loaded = true;
      notifyListeners();
    }
  }

  /// Добавить новый материал. [name] и [pricePerM2] обязательны;
  /// [minOrderM2] — необязательный минимальный заказ, м².
  Future<bool> add({
    required String name,
    required double pricePerM2,
    double? minOrderM2,
  }) async {
    final n = name.trim();
    if (n.isEmpty || pricePerM2 <= 0) return false;
    final id =
        'm-${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}';
    _custom.add(AssortmentItem(
      id: id,
      name: n,
      pricePerM2: pricePerM2,
      minOrderM2: (minOrderM2 != null && minOrderM2 > 0)
          ? minOrderM2
          : null,
    ));
    _selectedId = id;
    notifyListeners();
    try {
      await _save();
      return true;
    } catch (e) {
      _error = 'Не удалось сохранить материал: $e';
      notifyListeners();
      return false;
    }
  }

  /// Удалить пользовательский материал по [id] (примеры не удаляются).
  Future<bool> remove(String id) async {
    final before = _custom.length;
    _custom.removeWhere((a) => a.id == id);
    if (_custom.length == before) return false;
    if (_selectedId == id) _selectedId = null;
    notifyListeners();
    try {
      await _save();
      return true;
    } catch (e) {
      _error = 'Не удалось сохранить изменения: $e';
      notifyListeners();
      return false;
    }
  }

  /// Выбрать материал (id из [all]); null — вернуться к каталогу-примеру.
  Future<void> select(String? id) async {
    _selectedId = id;
    notifyListeners();
    try {
      await _save();
    } catch (e) {
      _error = 'Не удалось сохранить выбор: $e';
      notifyListeners();
    }
  }

  List<AssortmentItem> _parseItems(List<dynamic> items) {
    final out = <AssortmentItem>[];
    for (final e in items) {
      if (e is! Map) continue;
      final m = Map<String, dynamic>.from(e);
      final id = m['id'];
      final name = m['name'];
      if (id is! String || id.isEmpty || name is! String || name.isEmpty) {
        continue;
      }
      out.add(AssortmentItem(
        id: id,
        name: name,
        pricePerM2: (m['pricePerM2'] as num?)?.toDouble() ?? 0.0,
        minOrderM2: (m['minOrderM2'] as num?)?.toDouble(),
      ));
    }
    return out;
  }

  Future<void> _save() async {
    await _store.write(
      _file,
      const JsonEncoder.withIndent('  ').convert({
        'version': 1,
        'selected': _selectedId,
        'items': [
          for (final a in _custom)
            {
              'id': a.id,
              'name': a.name,
              'pricePerM2': a.pricePerM2,
              if (a.minOrderM2 != null) 'minOrderM2': a.minOrderM2,
            }
        ],
      }),
    );
  }
}
