// Пример теста-эталона. Реальные тесты добавляют агенты 01–08.
// Запуск: dart test/sample_test.dart  (из packages/core)
import '../tool/test_utils.dart';

void main() {
  expectEq(2 + 2, 4, 'арифметика');
  expectNear(304.8, 96 * 3.175, 'rapport эталон');
  ok('sample');
  // ignore: avoid_print
  print('Все тесты примера пройдены.');
}
