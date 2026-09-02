/// Мини-каркас тестов без внешних зависимостей (pub.dev недоступен).
///
/// Каждый тестовый файл `test/*_test.dart` обязан иметь `void main()`,
/// использующий функции отсюда, и завершаться кодом выхода 0 при успехе.
/// Запуск одного файла:  `dart test/<file>_test.dart`
/// Запуск всех тестов:  см. README (цикл по файлам).
library;

import 'dart:math' as math;

void expect(bool condition, String message) {
  if (!condition) {
    throw StateError('ОШИБКА ТЕСТА: $message');
  }
}

void expectEq<T>(T actual, T expected, String message, {double eps = 1e-9}) {
  if (actual is num && expected is num) {
    final ok = (actual - expected).abs() <= eps;
    if (!ok) {
      throw StateError('ОШИБКА ТЕСТА: $message: ожидалось $expected, получено $actual (eps=$eps)');
    }
  } else if (actual != expected) {
    throw StateError('ОШИБКА ТЕСТА: $message: ожидалось $expected, получено $actual');
  }
}

void expectNear(double actual, double expected, String message, {double eps = 1e-6}) {
  final ok = (actual - expected).abs() <= eps;
  if (!ok) {
    throw StateError('ОШИБКА ТЕСТА: $message: ожидалось $expected, получено $actual (eps=$eps)');
  }
}

void ok(String name) {
  // ignore: avoid_print
  print('OK: $name');
}

double rad(double deg) => deg * math.pi / 180.0;
