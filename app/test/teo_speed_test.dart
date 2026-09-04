// Регрессия: слайдер «Скорость, м/мин» в «Чувствительности» ТЭО обязан влиять
// на себестоимость. Раньше _recomputeSensitivity подставлял каталожную скорость
// машины, игнорируя _speed, — пересчёт ничего не менял.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:prepress_core/prepress_core.dart';
import 'package:prepress_planner/src/projects/project.dart';
import 'package:prepress_planner/src/screens/teo_screen.dart';

void main() {
  testWidgets('teo: скорость в чувствительности меняет себестоимость',
      (tester) async {
    // Большой «экран»: блок «Чувствительность» длинный, в стандартном
    // тестовом окне (800×600) нижние слайдеры не монтируются (ListView ленив).
    await tester.binding.setSurfaceSize(const Size(1400, 2800));
    try {
    await tester.runAsync(() async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: TeoScreen(
            project: Project(
              name: 'p',
              calc: computeMaterialAuto(LayoutParams()),
            ),
            onChange: (_) {},
          ),
        ),
      ));
      await tester.pump();

      // Базовый расчёт ТЭО — появляется блок «Чувствительность» с 3 слайдерами.
      await tester.ensureVisible(find.text('Рассчитать ТЭО'));
      await tester.pump();
      await tester.tap(find.text('Рассчитать ТЭО'));
      await tester.pump();
      await _waitUntil(tester, () => find.byType(Slider).evaluate().length >= 3,
          timeout: const Duration(seconds: 30));

      Future<double> costAt(double targetValue,
          {required String previousText}) async {
        // 3-й слайдер — «Скорость, м/мин» (порядок: цена, ставка, скорость).
        final slider = find.byType(Slider).at(2);
        await tester.ensureVisible(slider);
        await tester.pump();
        final rect = tester.getRect(slider);
        final frac = (targetValue - 10) / (300 - 10);
        await tester.tapAt(Offset(
            rect.left + rect.width * frac.clamp(0.0, 1.0), rect.center.dy));
        await tester.pump();
        await tester.ensureVisible(find.text('Пересчитать'));
        await tester.tap(find.text('Пересчитать'));
        final text = await _waitForCostText(tester,
            notEqualTo: previousText);
        final m = RegExp(r'([\d]+[.,]?[\d]*)\s*₽').firstMatch(text);
        return double.parse((m?.group(1) ?? '0').replaceAll(',', '.'));
      }

      // Быстрый прогон — даёт первый результат «Себестоимость 1000 шт: …».
      final fast = await costAt(300, previousText: '');
      final slow =
          await costAt(10, previousText: _costLine(fast));
      expect(fast, greaterThan(0));
      expect(slow, greaterThan(fast),
          reason: 'себестоимость должна расти при снижении скорости '
              '(fast=$fast, slow=$slow)');
    });
    } finally {
      await tester.binding.setSurfaceSize(null);
    }
  });
}

String _costLine(double value) => 'Себестоимость 1000 шт: '
    '${value.toStringAsFixed(2)} ₽';

/// Ждёт появления строки «Себестоимость 1000 шт: …», при [notEqualTo] — пока
/// значение не изменится относительно старого (пересчёт ещё идёт в изоляте).
Future<String> _waitForCostText(WidgetTester tester,
    {String notEqualTo = ''}) async {
  final deadline = DateTime.now().add(const Duration(seconds: 30));
  String? text;
  while (DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 40));
    await tester.pump();
    final f = find.textContaining('Себестоимость 1000 шт');
    if (f.evaluate().isNotEmpty) {
      final t = (tester.widget<Text>(f).data ?? '').trim();
      if (notEqualTo.isEmpty || t != notEqualTo) {
        text = t;
        break;
      }
    }
  }
  if (text == null) {
    throw StateError('Строка себестоимости не появилась/не обновилась');
  }
  return text;
}

/// Ждёт, пока [cond] станет истиной, прокачивая кадры (реальный изолят).
Future<void> _waitUntil(WidgetTester tester, bool Function() cond,
    {Duration timeout = const Duration(seconds: 30)}) async {
  final deadline = DateTime.now().add(timeout);
  while (!cond() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 40));
    await tester.pump();
  }
  if (!cond()) {
    throw StateError('Условие не выполнено за $timeout');
  }
}
