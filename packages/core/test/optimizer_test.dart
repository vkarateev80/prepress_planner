// Тесты оптимизации расхода — порт cam_material/tests/test_optimizer.py.
import '../tool/test_utils.dart';
import '../lib/src/model/params.dart';
import '../lib/src/calculator/material.dart';
import '../lib/src/calculator/layout_optimizer.dart';

LayoutParams makeParams({
  double labelW = 50,
  double labelH = 30,
  double gapX = 3,
  double gapY = 3,
  int zTeeth = 96,
  double cp = 3.175,
  double cylWidth = 300,
  double webWidth = 300,
  double minGap = 3,
  String mode = 'count',
  int count = 5000,
}) =>
    LayoutParams(
      labelW: labelW,
      labelH: labelH,
      gapX: gapX,
      gapY: gapY,
      zTeeth: zTeeth,
      cp: cp,
      cylWidth: cylWidth,
      webWidth: webWidth,
      minGap: minGap,
      mode: mode,
      count: count,
    );

void testBestVariantBasic() {
  final p = makeParams();
  final best = enumerateVariants(p, limit: 1).first;
  // максимум этикеток за оборот = 9*5
  expectEq(best.rows, 9, 'rows лучшего');
  expectEq(best.cols, 5, 'cols лучшего');
  expect(!best.rotated, 'лучший не повёрнут');
  expectEq(best.perRev, 45, 'perRev лучшего');
  ok('best_variant_basic');
}

void testRotationHelpsWhenWebNarrow() {
  // узкое полотно 250 мм, этикетка широкая 60x30:
  // без поворота 9 рядов * 4 колонки = 36, с поворотом (30x60) 4*7 = 28
  final p = makeParams(labelW: 60, labelH: 30, webWidth: 250);
  final best = enumerateVariants(p, limit: 1).first;
  expect(!best.rotated, '60x30 на 250 мм: лучший не повёрнут');
  expectEq(best.perRev, 36, '60x30 на 250 мм: perRev');

  // высокая этикетка 30x60: поворот даёт 36 вместо 28
  final p2 = makeParams(labelW: 30, labelH: 60, webWidth: 250);
  final best2 = enumerateVariants(p2, limit: 1).first;
  expect(best2.rotated, '30x60 на 250 мм: лучший повёрнут');
  expectEq(best2.perRev, 36, '30x60 на 250 мм: perRev');
  ok('rotation_helps_web_narrow');
}

void testNarrowWeb180() {
  // полотно 180 мм, этикетка 60x30: повёрнутый (4 ряда x 5 колонок = 20)
  // лучше обычного (9 x 2 = 18) — сверено с живым оракулом optimizer.py.
  final p = makeParams(labelW: 60, labelH: 30, webWidth: 180);
  final best = enumerateVariants(p, limit: 1).first;
  expect(best.rotated, '60x30 на 180 мм: лучший повёрнут');
  expectEq(best.perRev, 20, '60x30 на 180 мм: perRev');
  // этикетка 50x30 на 180 мм: обычная ориентация всё же лучше (9x3=27 > 5x5=25)
  final p2 = makeParams(labelW: 50, labelH: 30, webWidth: 180);
  final best2 = enumerateVariants(p2, limit: 1).first;
  expect(!best2.rotated, '50x30 на 180 мм: лучший не повёрнут');
  expectEq(best2.perRev, 27, '50x30 на 180 мм: perRev');
  ok('narrow_web_180');
}

void testVariantsSortedAndValid() {
  final p = makeParams();
  final variants = enumerateVariants(p);
  expect(variants.length > 5, 'вариантов больше 5, получено ${variants.length}');
  for (var i = 1; i < variants.length; i++) {
    expect(variants[i - 1].perLabelArea <= variants[i].perLabelArea + 1e-9,
        'сортировка по perLabelArea на позиции $i');
  }
  final effWidth = p.cylWidth < p.webWidth ? p.cylWidth : p.webWidth;
  for (final v in variants) {
    expect(v.error == null, 'вариант без ошибки');
    // условие сходимости шва (stepY округлён до 4 знаков)
    expectNear(v.stepY * v.rows, v.rapport, 'сходимость шва',
        eps: 1e-3);
    // ширина не превышает доступную
    expect(v.usedWidth <= effWidth + 1e-6,
        'usedWidth ${v.usedWidth} <= $effWidth');
    // фактический зазор по Y не меньше минимального
    expect(v.gapYActual >= p.minGap - 1e-6,
        'gapYActual ${v.gapYActual} >= ${p.minGap}');
  }
  ok('variants_sorted_and_valid');
}

void main() {
  testBestVariantBasic();
  testRotationHelpsWhenWebNarrow();
  testNarrowWeb180();
  testVariantsSortedAndValid();
  // ignore: avoid_print
  print('Все тесты оптимизации пройдены.');
}
