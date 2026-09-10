/// Переменные окружения на desktop и «пусто» на web (в браузере env нет).
library;

import 'env_io.dart' if (dart.library.html) 'env_web.dart' as impl;

/// Web ли сборка (браузер).
bool get isWeb => impl.isWeb;

/// Мобильная ли сборка (Android/iOS): там нет ни файлового браузера desktop,
/// ни браузерного picker'а web, и запись возможна только в каталог приложения.
bool get isMobile => impl.isMobile;

/// Значение env-переменной [key]; на web всегда '' (серверные адреса в
/// браузере задаются сборкой/прокси, а не переменными окружения).
String envOrDefault(String key, String fallback) =>
    impl.envOrDefault(key, fallback);
