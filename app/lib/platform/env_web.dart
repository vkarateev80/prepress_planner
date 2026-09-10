/// Окружение на web: переменных окружения нет.
library;

const bool isWeb = true;

/// В браузере мобильной платформы нет: файл выбирается <input type=file>,
/// запись отчётов делает сам браузер.
const bool isMobile = false;

String envOrDefault(String key, String fallback) => '';
