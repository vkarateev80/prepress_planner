/// ТЭО варианта раскроя: статьи затрат, себестоимость, загрузка смены,
/// сравнение вариантов и break-even (агент 07). Потребляет аг.05
/// (`MaterialResult`, `Consumption`).
///
/// Округления: деньги — 2 знака, время — 4 знака, costPer1000 — 2 знака.
///
/// ФОРМУЛА МАШИННОГО ВРЕМЕНИ (важно):
///   runTime = calc.length (мм) / (speedMetersPerMin * 1000) / 60  — ЧАСЫ.
///   Т.е. метры → минуты (метры / м/мин) → часы (минуты / 60).
///   Пример: длина 34137.6 мм = 34.1376 м при 100 м/мин — это 0.341376 МИНУТЫ
///   = 0.0056896 ч работы. Ранняя версия контракта (agents/07_economics.md)
///   ошибочно приводила runTime ≈ 0.3414 ч, читая 100 м/мин как 100 м/ч;
///   здесь сохранена дословная формула контракта.
library;

import 'dart:math' as math;

import 'assortment.dart';
import 'machine.dart';
import '../calculator/material.dart';
import '../calculator/consumption.dart';

double _round(double v, int n) {
  final f = math.pow(10.0, n).toDouble();
  return (v * f).roundToDouble() / f;
}

double _round4(double v) => _round(v, 4);
double _round2(double v) => _round(v, 2);

/// Вход ТЭО: сортамент, машина, рабочее время, оснастка и наценка.
class TeoInput {
  final AssortmentItem material;
  final Machine machine;
  final WorkTime workTime;
  final double toolingCost; // ₽/заказ, 0 — нет
  final double markupPct; // % от (материал + машина + оснастка), 0 — нет

  const TeoInput({
    required this.material,
    required this.machine,
    this.workTime = const WorkTime(),
    this.toolingCost = 0,
    this.markupPct = 0,
  });
}

/// Результат ТЭО варианта раскроя. [error] != null — расчёт невозможен
/// (все числовые поля при ошибке нулевые).
class TeoResult {
  final String? error; // null = успех
  final double runTimeHours; // машинное время печати
  final double setupTimeHours; // переналадка
  final double totalTimeHours; // runTime + setup
  final double machineCost; // ₽
  final double materialCost; // ₽
  final double toolingCost; // ₽
  final double markupCost; // ₽
  final double totalCost; // ₽
  final double costPer1000; // ₽/1000 шт
  final double costPerLabel; // ₽/шт
  final double labelsPerHour; // производительность, шт/ч
  final double labelsPerShift; // производительность, шт/смену
  final double shiftLoadPct; // totalTime / (ч/смену·смен)·100
  final bool fitsShift; // shiftLoadPct <= 100

  const TeoResult({
    this.error,
    this.runTimeHours = 0,
    this.setupTimeHours = 0,
    this.totalTimeHours = 0,
    this.machineCost = 0,
    this.materialCost = 0,
    this.toolingCost = 0,
    this.markupCost = 0,
    this.totalCost = 0,
    this.costPer1000 = 0,
    this.costPerLabel = 0,
    this.labelsPerHour = 0,
    this.labelsPerShift = 0,
    this.shiftLoadPct = 0,
    this.fitsShift = false,
  });

  /// Результат-ошибка: поля нулевые, [error] заполнен.
  factory TeoResult.withError(String message) => TeoResult(error: message);
}

/// Расчёт ТЭО варианта раскроя.
///
/// Внутренние расчёты ведутся по неокруглённым значениям; в результат
/// кладутся округлённые поля (время 4 знака, деньги 2 знака).
TeoResult computeTeo(MaterialResult calc, Consumption cons, TeoInput input) {
  final speed = input.machine.speedMetersPerMin;
  final perHour = input.machine.labelsPerHour;
  final hasSpeed = speed != null && speed > 0;
  final hasPerHour = perHour != null && perHour > 0;
  if (!hasSpeed && !hasPerHour) {
    return TeoResult.withError(
        'Задайте скорость печати (м/мин) или производительность (этикеток/ч)');
  }

  // 1) Машинное время печати, ч.
  //    speed: length (мм) → метры → минуты (м / м/мин) → часы (мин / 60):
  //          length / (speed*1000) / 60 — дословно формула контракта.
  //    labelsPerHour: N / производительность.
  final double run;
  if (hasSpeed) {
    run = calc.length / (speed! * 1000.0) / 60.0;
  } else {
    run = calc.count / perHour!.toDouble();
  }
  final setup = input.machine.setupTimeHours;

  // 2) Статьи затрат (по неокруглённым значениям).
  final machineCostRaw = (setup + run) * input.machine.ratePerHour;
  final materialCostRaw = cons.areaM2 * input.material.pricePerM2;
  final toolingRaw = input.toolingCost;
  final markupRaw =
      input.markupPct * (materialCostRaw + machineCostRaw + toolingRaw) / 100.0;
  final totalRaw = materialCostRaw + machineCostRaw + toolingRaw + markupRaw;

  // 3) Загрузка смены.
  final capacity =
      input.workTime.hoursPerShift * input.workTime.shiftsPerDay.toDouble();
  final runHours = _round4(run);
  final totalHours = _round4(setup + run);
  final shiftLoad = capacity > 0 ? totalHours / capacity * 100.0 : 0.0;

  final count = calc.count;
  final labelsPerHour = runHours > 0 ? count / runHours : 0.0;

  return TeoResult(
    runTimeHours: runHours,
    setupTimeHours: _round4(setup),
    totalTimeHours: totalHours,
    machineCost: _round2(machineCostRaw),
    materialCost: _round2(materialCostRaw),
    toolingCost: _round2(toolingRaw),
    markupCost: _round2(markupRaw),
    totalCost: _round2(totalRaw),
    costPer1000: count > 0 ? _round2(totalRaw / count * 1000.0) : 0.0,
    costPerLabel: count > 0 ? _round2(totalRaw / count) : 0.0,
    labelsPerHour: labelsPerHour,
    labelsPerShift: labelsPerHour * input.workTime.hoursPerShift,
    shiftLoadPct: shiftLoad,
    fitsShift: capacity > 0 && shiftLoad <= 100.0,
  );
}

/// Сравнение ТЭО вариантов раскроя.
class TeoComparison {
  /// Посчитанные варианты (ошибочные пропущены), лучший первый по costPer1000.
  final List<(MaterialResult, TeoResult)> variants;

  /// Индекс лучшего варианта в ИСХОДНОМ списке, переданном в
  /// [compareTeoVariants] (для сопоставления с нумерацией enumerateVariants);
  /// -1 — если нет ни одного успешного варианта.
  final int bestIndex;

  final double bestCostPer1000; // costPer1000 лучшего (₽/1000 шт)
  final double baseCostPer1000; // лучший не-rotated вариант (или лучший, если не-rotated нет)
  final double savingsPer1000; // base − best, ₽ (>= 0)
  final double savingsPct; // (base − best)/base·100, % (base > 0)

  const TeoComparison({
    required this.variants,
    required this.bestIndex,
    required this.bestCostPer1000,
    required this.baseCostPer1000,
    required this.savingsPer1000,
    required this.savingsPct,
  });
}

/// ТЭО всех вариантов [variants] (например, из аг.05 enumerateVariants) и
/// сортировка по себестоимости 1000 шт (лучший первый). [consFor] строит
/// [Consumption] для конкретного варианта (форма этикетки зависит от rotated).
/// Варианты с ошибкой расчёта пропускаются.
TeoComparison compareTeoVariants(
  List<MaterialResult> variants,
  Consumption Function(MaterialResult) consFor,
  TeoInput input,
) {
  final ok = <({MaterialResult v, TeoResult t, int orig})>[];
  for (var i = 0; i < variants.length; i++) {
    final v = variants[i];
    final teo = computeTeo(v, consFor(v), input);
    if (teo.error == null) ok.add((v: v, t: teo, orig: i));
  }
  if (ok.isEmpty) {
    return const TeoComparison(
      variants: [],
      bestIndex: -1,
      bestCostPer1000: 0,
      baseCostPer1000: 0,
      savingsPer1000: 0,
      savingsPct: 0,
    );
  }

  // Стабильная сортировка по costPer1000 (при равенстве — исходный порядок).
  final order = List<int>.generate(ok.length, (i) => i);
  order.sort((i, j) {
    final c = ok[i].t.costPer1000.compareTo(ok[j].t.costPer1000);
    if (c != 0) return c;
    return ok[i].orig.compareTo(ok[j].orig);
  });
  final sorted = [for (final i in order) (ok[i].v, ok[i].t)];
  final bestEntry = ok[order.first];
  final best = bestEntry.t.costPer1000;

  // База: лучший (мин. costPer1000) среди не-rotated; иначе — сам лучший.
  double? base;
  for (final e in ok) {
    if (e.v.rotated) continue;
    if (base == null || e.t.costPer1000 < base) base = e.t.costPer1000;
  }
  base ??= best;
  var savings = base - best;
  if (savings < 0) savings = 0.0;
  final savingsPct = base > 0 ? (base - best) / base * 100.0 : 0.0;

  return TeoComparison(
    variants: sorted,
    bestIndex: bestEntry.orig,
    bestCostPer1000: best,
    baseCostPer1000: base,
    savingsPer1000: _round2(savings),
    savingsPct: savingsPct,
  );
}

/// Точка безубыточности перехода с варианта A на вариант B, шт этикеток:
///   N* = (toolingB − toolingA) / ((costPer1000A − costPer1000B)/1000)
/// где costPer1000 — себестоимость 1000 шт (без учёта оснастки этого заказа;
/// оснастка передаётся отдельными аргументами).
///
/// Если B не дешевле на этикетку (знаменатель <= 0) или N* <= 0 — вариант B
/// выгоден всегда, возвращается 0.
double breakEvenQuantity(
  MaterialResult variantA,
  TeoResult teoA,
  double toolingA,
  MaterialResult variantB,
  TeoResult teoB,
  double toolingB,
) {
  final denom = (teoA.costPer1000 - teoB.costPer1000) / 1000.0;
  if (denom <= 0) return 0.0;
  final n = (toolingB - toolingA) / denom;
  return n <= 0 ? 0.0 : n;
}
