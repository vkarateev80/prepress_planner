// Тесты экономики/ТЭО (агент 07) — packages/core/test/economics_test.dart
// Запуск: dart test/economics_test.dart (из packages/core)
//
// ПРИМЕЧАНИЕ О ФОРМУЛЕ runTime (важно для эталона ниже):
//   runTime = calc.length (мм) / (speedMetersPerMin * 1000) / 60  — ЧАСЫ.
//   Эталон 50×30 (LayoutParams по умолчанию): length = 34137.6 мм = 34.1376 м.
//   При скорости 100 м/мин время печати = 34.1376 / 100 = 0.341376 МИНУТЫ
//   = 0.0056896 ЧАСА. Так что runTime ≈ 0.0057 ч — это верно: 34 м полотна при
//   100 м/мин — это 0.34 минуты работы печатной машины, а не 0.34 часа.
//   Ранняя версия контракта (agents/07_economics.md) приводила runTime ≈ 0.3414 ч
//   — там скорость 100 м/мин была по ошибке прочитана как 100 м/ч. Формула из
//   контракта (length/(speed*1000)/60) сохранена дословно, поэтому тест считает
//   runTime ≈ 0.0057 ч, machineCost ≈ 2528.45 ₽, costPer1000 ≈ 704.88 ₽.
import 'dart:convert';

import '../tool/test_utils.dart';
import '../lib/src/model/params.dart';
import '../lib/src/calculator/material.dart';
import '../lib/src/calculator/shape.dart';
import '../lib/src/calculator/consumption.dart';
import '../lib/src/calculator/layout_optimizer.dart';
import '../lib/src/economics/assortment.dart';
import '../lib/src/economics/machine.dart';
import '../lib/src/economics/teo.dart';
import '../lib/src/economics/price_catalog.dart';

const _paper = AssortmentItem(
    id: 'paper-sa-80', name: 'Бумага самоклеящаяся 80 г/м²', pricePerM2: 100.0);
const _flexo = Machine(
    id: 'flexo-300',
    name: 'Флексопечать 300 мм',
    ratePerHour: 5000.0,
    speedMetersPerMin: 100.0,
    setupTimeHours: 0.5);

Consumption _consRect(MaterialResult v) =>
    computeConsumption(v, shapeFromPreset('rect', v.labelW, v.labelH));

void testReferenceTeo() {
  // Эталон 1: этикетка 50×30, сетка из аг.05 (дефолты LayoutParams дают ровно
  // rows=9, cols=5, count=5040, length=34137.6 мм, areaMm2 = 112*304.8*300).
  final calc = computeMaterialAuto(LayoutParams());
  expect(calc.error == null, calc.error ?? 'расчёт не удался');
  expectEq(calc.rows, 9, 'rows=9');
  expectEq(calc.cols, 5, 'cols=5');
  expectEq(calc.count, 5040, 'count=5040');
  expectNear(calc.length, 34137.6, 'length=34137.6 мм', eps: 0.01);

  final cons = computeConsumption(calc, shapeFromPreset('rect', 50.0, 30.0));
  expectNear(cons.areaM2, 10.24128, 'areaM2 = 10.24128 м² (аг.05 хранит 4 знака)',
      eps: 1e-4);

  const input = TeoInput(
      material: _paper,
      machine: _flexo,
      workTime: WorkTime(hoursPerShift: 8, shiftsPerDay: 1));

  final r = computeTeo(calc, cons, input);
  expect(r.error == null, r.error ?? 'ТЭО не удалось');

  // Время печати: 34.1376 м / 100 м/мин = 0.341376 мин = 0.0056896 ч.
  expectNear(r.runTimeHours, 0.0056896, 'runTimeHours ≈ 0.0057 ч', eps: 1e-4);
  expectEq(r.runTimeHours.toStringAsFixed(4), '0.0057', 'runTime: время 4 знака');
  expectEq(r.setupTimeHours.toStringAsFixed(4), '0.5000', 'setup: время 4 знака');
  expectEq(r.totalTimeHours.toStringAsFixed(4), '0.5057', 'totalTime: время 4 знака');
  expectNear(r.totalTimeHours, 0.5057, 'totalTime ≈ 0.5057 ч', eps: 1e-4);

  // machineCost = (0.5 + 0.0056896) * 5000 = 2528.448 → 2528.45 ₽
  expectEq(r.machineCost.toStringAsFixed(2), '2528.45', 'machineCost: деньги 2 знака');
  expectNear(r.machineCost, 2528.45, 'machineCost', eps: 1e-3);

  // materialCost = 10.24128 * 100 = 1024.128 → 1024.13 ₽
  expectEq(r.materialCost.toStringAsFixed(2), '1024.13', 'materialCost: деньги 2 знака');
  expectNear(r.materialCost, 1024.13, 'materialCost', eps: 1e-3);

  expectEq(r.toolingCost, 0.0, 'tooling=0');
  expectEq(r.markupCost, 0.0, 'markup=0');

  // total = 2528.448 + 1024.128 = 3552.576 → 3552.58 ₽
  expectEq(r.totalCost.toStringAsFixed(2), '3552.58', 'totalCost: деньги 2 знака');
  expectNear(r.totalCost, 3552.58, 'totalCost ≈ 3552.6', eps: 0.01);

  // costPer1000 = 3552.576/5040*1000 = 704.8766 → 704.88 ₽
  expectEq(r.costPer1000.toStringAsFixed(2), '704.88', 'costPer1000: 2 знака');
  expectNear(r.costPer1000, 704.88, 'costPer1000 ≈ 704.9', eps: 0.01);
  expectEq(r.costPerLabel.toStringAsFixed(2), '0.70', 'costPerLabel: деньги 2 знака');

  // Производительность и смена.
  expectNear(r.labelsPerHour * r.runTimeHours, 5040.0,
      'labelsPerHour = count / runTime', eps: 0.01);
  expectNear(r.labelsPerShift, r.labelsPerHour * 8.0,
      'labelsPerShift = labelsPerHour * смена', eps: 1e-6);

  // shiftLoad = totalTime / (8ч * 1 смена) * 100 = 0.5057/8*100 ≈ 6.32%.
  expectNear(r.shiftLoadPct, 0.5057 / 8.0 * 100.0, 'shiftLoad ≈ 6.32%', eps: 1e-3);
  expect(r.fitsShift, 'заказ помещается в смену');
  ok('reference_teo');
}

void testCompareVariants() {
  // Эталон 2: enumerateVariants аг.05 + ТЭО по каждому варианту.
  final variants = enumerateVariants(LayoutParams());
  expect(variants.length >= 2, 'вариантов достаточно (${variants.length})');
  expect(variants.any((v) => !v.rotated), 'есть не-rotated вариант');
  expect(variants.any((v) => v.rotated), 'есть rotated вариант');

  const input = TeoInput(material: _paper, machine: _flexo);
  final cmp = compareTeoVariants(variants, _consRect, input);
  expect(cmp.variants.length == variants.length,
      'все варианты посчитаны (${cmp.variants.length}/${variants.length})');

  // Лучший первый: сортировка по costPer1000 (не убывание).
  for (var i = 1; i < cmp.variants.length; i++) {
    expect(cmp.variants[i - 1].$2.costPer1000 <= cmp.variants[i].$2.costPer1000 + 1e-9,
        'сортировка по costPer1000 на позиции $i');
  }

  final best = cmp.variants.first.$2.costPer1000;
  expectNear(cmp.bestCostPer1000, best, 'bestCostPer1000 = лучший вариант', eps: 1e-9);
  expect(cmp.bestIndex >= 0 && cmp.bestIndex < variants.length,
      'bestIndex в диапазоне входного списка');
  expect(cmp.variants.first.$1 == variants[cmp.bestIndex],
      'bestIndex указывает на лучший вариант исходного списка');

  // База: лучший (мин. costPer1000) среди не-rotated вариантов.
  double? baseExpect;
  for (final e in cmp.variants) {
    if (e.$1.rotated) continue;
    if (baseExpect == null || e.$2.costPer1000 < baseExpect) {
      baseExpect = e.$2.costPer1000;
    }
  }
  expect(baseExpect != null, 'есть не-rotated база');
  expectNear(cmp.baseCostPer1000, baseExpect!, 'baseCostPer1000', eps: 1e-9);

  expect(cmp.savingsPer1000 >= -1e-9, 'savings >= 0');
  expectNear(cmp.savingsPer1000, cmp.baseCostPer1000 - cmp.bestCostPer1000,
      'savingsPer1000 = base - best', eps: 0.01);
  final base = cmp.baseCostPer1000;
  final pct = base > 0 ? (base - cmp.bestCostPer1000) / base * 100.0 : 0.0;
  expectNear(cmp.savingsPct, pct, 'savingsPct', eps: 1e-6);
  ok('compare_variants');
}

void testBreakEven() {
  // Эталон 3: A — расточительная раскладка (1×1: этикетка одна на раппорт),
  // B — оптимальная автораскладка (9×5). B дешевле на этикетку.
  final p = LayoutParams();
  final a = computeMaterial(p, rows: 1, cols: 1, rotated: false);
  final b = computeMaterialAuto(p);
  expect(a.error == null && b.error == null, 'варианты валидны');
  expectEq(a.count, 5000, 'A: count=5000');
  expectEq(b.count, 5040, 'B: count=5040');

  const input = TeoInput(material: _paper, machine: _flexo);
  final teoA = computeTeo(a, _consRect(a), input);
  final teoB = computeTeo(b, _consRect(b), input);
  expect(teoA.error == null && teoB.error == null, 'ТЭО валидны');
  expect(teoA.costPer1000 > teoB.costPer1000,
      'B дешевле на этикетку (${teoA.costPer1000} vs ${teoB.costPer1000})');

  // Оснастка B дороже (новая форма/гильза) → N* > 0 по формуле.
  const toolingA = 0.0;
  const toolingB = 40000.0;
  final n = breakEvenQuantity(a, teoA, toolingA, b, teoB, toolingB);
  final expected =
      (toolingB - toolingA) / ((teoA.costPer1000 - teoB.costPer1000) / 1000.0);
  expect(n > 0, 'N* > 0 при дорогой оснастке B, получено $n');
  expect(n > 1000, 'N* осмысленный (${n.toStringAsFixed(1)} шт)');
  expectNear(n, expected, 'N* по формуле контракта', eps: 1e-3);

  // Одинаковая оснастка → B выгоден всегда → 0.
  expectEq(breakEvenQuantity(a, teoA, 0.0, b, teoB, 0.0), 0.0,
      'равная оснастка → 0');
  // B дешевле ещё и по оснастке → 0.
  expectEq(breakEvenQuantity(a, teoA, 10000.0, b, teoB, 0.0), 0.0,
      'B выгоден всегда → 0');
  // Второй вариант дороже на этикетку (знаменатель <= 0) → 0.
  expectEq(breakEvenQuantity(b, teoB, 0.0, a, teoA, 0.0), 0.0,
      'знаменатель <= 0 → 0');
  ok('break_even');
}

void testErrors() {
  // Эталон 4: машина без скорости и без производительности → ошибка.
  final calc = computeMaterialAuto(LayoutParams());
  final cons = computeConsumption(calc, shapeFromPreset('rect', 50.0, 30.0));
  const machineNoPerf = Machine(id: 'm', name: 'Машина без паспорта', ratePerHour: 5000.0);
  const input = TeoInput(material: _paper, machine: machineNoPerf);
  final r = computeTeo(calc, cons, input);
  expect(r.error != null, 'нет скорости/производительности — нужна ошибка');
  expect(r.error!.contains('Задайте скорость печати (м/мин)'),
      'текст ошибки: ${r.error}');
  expectEq(r.totalCost, 0.0, 'при ошибке поля нулевые');
  expectEq(r.runTimeHours, 0.0, 'runTime=0 при ошибке');
  expect(!r.fitsShift, 'fitsShift=false при ошибке');

  // Скорость 0 тоже считается незаданной.
  const machineZero = Machine(
      id: 'm', name: 'Машина', ratePerHour: 5000.0, speedMetersPerMin: 0.0);
  final r2 = computeTeo(calc, cons, TeoInput(material: _paper, machine: machineZero));
  expect(r2.error != null, 'speed=0 → ошибка');
  ok('errors');
}

void testCatalogJson() {
  // Эталон 5: PriceCatalog.defaults() → toJson → fromJson → те же поля.
  final cat = PriceCatalog.defaults();
  expectEq(cat.currency, '₽', 'валюта');
  expectEq(cat.assortment.length, 3, '3 сортамента');
  expectEq(cat.machines.length, 2, '2 машины');
  expect(cat.assortment.every((a) => a.name.contains('(пример)')),
      'в сортаменте пометка «(пример)»');
  expect(cat.machines.every((m) => m.name.contains('(пример)')),
      'в машинах пометка «(пример)»');

  final text = jsonEncode(cat.toJson());
  final decoded = jsonDecode(text) as Map<String, dynamic>;
  final cat2 = PriceCatalog.fromJson(decoded);

  expectEq(cat2.currency, '₽', 'currency round-trip');
  expectNear(cat2.workTime.hoursPerShift, 8.0, 'hoursPerShift', eps: 1e-9);
  expectEq(cat2.workTime.shiftsPerDay, 1, 'shiftsPerDay');
  expectEq(cat2.assortment.length, cat.assortment.length, 'сортамент: длина');
  for (var i = 0; i < cat.assortment.length; i++) {
    final a = cat.assortment[i];
    final a2 = cat2.assortment[i];
    expectEq(a.id, a2.id, 'сортамент[$i].id');
    expectEq(a.name, a2.name, 'сортамент[$i].name');
    expectNear(a.pricePerM2, a2.pricePerM2, 'сортамент[$i].price', eps: 1e-9);
    expectEq(a.minOrderM2, a2.minOrderM2, 'сортамент[$i].minOrderM2');
  }
  expectEq(cat2.machines.length, cat.machines.length, 'машины: длина');
  for (var i = 0; i < cat.machines.length; i++) {
    final m = cat.machines[i];
    final m2 = cat2.machines[i];
    expectEq(m.id, m2.id, 'машина[$i].id');
    expectEq(m.name, m2.name, 'машина[$i].name');
    expectNear(m.ratePerHour, m2.ratePerHour, 'машина[$i].rate', eps: 1e-9);
    expectNear(m.setupTimeHours, m2.setupTimeHours, 'машина[$i].setup', eps: 1e-9);
    expectEq(m.speedMetersPerMin, m2.speedMetersPerMin, 'машина[$i].speed');
    expectEq(m.labelsPerHour, m2.labelsPerHour, 'машина[$i].labelsPerHour');
  }

  // Nullable-поля отсутствуют в JSON при null и восстанавливаются как null.
  final machineList = (decoded['machines'] as List).cast<Map<String, dynamic>>();
  expect(machineList[0].containsKey('speedMetersPerMin'),
      'flexo: speed задан и присутствует');
  expect(!machineList[0].containsKey('labelsPerHour'),
      'flexo: labelsPerHour отсутствует (null)');
  expect(!machineList[1].containsKey('speedMetersPerMin'),
      'digital: speed отсутствует (null)');
  expect(machineList[1].containsKey('labelsPerHour'),
      'digital: labelsPerHour присутствует');

  final withNulls = PriceCatalog(
    assortment: const [
      AssortmentItem(id: 'x', name: 'X без мин. заказа', pricePerM2: 12.5),
    ],
    machines: const [
      Machine(id: 'y', name: 'Y без скорости', ratePerHour: 1.0, setupTimeHours: 2.0),
    ],
  );
  final m0 = withNulls.toJson();
  final ass = (m0['assortment'] as List).cast<Map<String, dynamic>>();
  expect(!ass[0].containsKey('minOrderM2'), 'minOrderM2 отсутствует при null');
  final mac = (m0['machines'] as List).cast<Map<String, dynamic>>();
  expect(!mac[0].containsKey('speedMetersPerMin'), 'speed отсутствует при null');
  expect(!mac[0].containsKey('labelsPerHour'), 'labelsPerHour отсутствует при null');
  expect(mac[0].containsKey('setupTimeHours'), 'setupTimeHours присутствует всегда');

  final back = PriceCatalog.fromJson(
      jsonDecode(jsonEncode(m0)) as Map<String, dynamic>);
  expectEq(back.assortment[0].minOrderM2, null, 'minOrderM2 → null');
  expectEq(back.machines[0].speedMetersPerMin, null, 'speed → null');
  expectEq(back.machines[0].labelsPerHour, null, 'labelsPerHour → null');
  ok('catalog_json');
}

void testRoundingAndMarkup() {
  // Эталон 6: деньги 2 знака, время 4 знака, costPer1000 2 знака.
  // Машина без скорости, производительность 2000 этикеток/ч → время ровно 1 ч,
  // все числа точные, наценка 10% и оснастка 50 ₽.
  // Числа подобраны так, чтобы округление до 2 знаков было однозначным
  // (без «десятичных половин»: 1265/2000 = 0.6325 → 0.63, 1265/2000*1000
  // = 632.5 → 632.50 — оба значения не зависят от двоичного представления).
  const material = AssortmentItem(id: 'paper', name: 'Бумага', pricePerM2: 100.0);
  const machine = Machine(
      id: 'm', name: 'М', ratePerHour: 1000.0, labelsPerHour: 2000, setupTimeHours: 0.0);
  const input = TeoInput(
      material: material,
      machine: machine,
      toolingCost: 50.0,
      markupPct: 10.0);
  const calc = MaterialResult(count: 2000, length: 30000.0);
  const cons = Consumption(
      areaMm2: 1e6,
      areaM2: 1.0,
      usedAreaMm2: 0.0,
      wasteMm2: 0.0,
      wastePct: 0.0,
      perLabelMm2: 0.0,
      webMin: 0.0);

  final r = computeTeo(calc, cons, input);
  expect(r.error == null, r.error ?? 'ТЭО не удалось');

  // Ветка labelsPerHour: runTime = 2000/2000 = 1 ч.
  expectNear(r.runTimeHours, 1.0, 'runTime = N/labelsPerHour', eps: 1e-9);
  expectEq(r.runTimeHours.toStringAsFixed(4), '1.0000', 'runTime 4 знака');
  expectEq(r.totalTimeHours.toStringAsFixed(4), '1.0000', 'totalTime 4 знака');

  // Деньги — 2 знака в хранимом значении.
  expectEq(r.machineCost.toStringAsFixed(2), '1000.00', 'machineCost');
  expectEq(r.materialCost.toStringAsFixed(2), '100.00', 'materialCost');
  expectEq(r.toolingCost.toStringAsFixed(2), '50.00', 'toolingCost');
  // markup = 10% * (100 + 1000 + 50) = 115.
  expectEq(r.markupCost.toStringAsFixed(2), '115.00', 'markupCost');
  expectEq(r.totalCost.toStringAsFixed(2), '1265.00', 'totalCost');
  expectEq(r.costPer1000.toStringAsFixed(2), '632.50', 'costPer1000');
  // 1265/2000 = 0.6325 → округление денег 2 знака → 0.63.
  expectEq(r.costPerLabel.toStringAsFixed(2), '0.63', 'costPerLabel');

  // Поля уже хранят округлённые значения (повторное округление не меняет).
  for (final v in [r.machineCost, r.materialCost, r.toolingCost, r.markupCost,
                   r.totalCost, r.costPer1000, r.costPerLabel]) {
    expectEq(double.parse(v.toStringAsFixed(2)), v, 'деньги хранятся с 2 знаками');
  }
  for (final v in [r.runTimeHours, r.setupTimeHours, r.totalTimeHours]) {
    expectEq(double.parse(v.toStringAsFixed(4)), v, 'время хранится с 4 знаками');
  }

  expectNear(r.labelsPerHour, 2000.0, 'labelsPerHour = 2000', eps: 1e-9);
  expectNear(r.labelsPerShift, 16000.0, 'labelsPerShift = 16000', eps: 1e-9);
  expectNear(r.shiftLoadPct, 1.0 / 8.0 * 100.0, 'shiftLoad = 12.5%', eps: 1e-9);
  expect(r.fitsShift, 'fitsShift');
  ok('rounding_and_markup');
}

void main() {
  testReferenceTeo();
  testCompareVariants();
  testBreakEven();
  testErrors();
  testCatalogJson();
  testRoundingAndMarkup();
  // ignore: avoid_print
  print('Все тесты экономики/ТЭО пройдены.');
}
