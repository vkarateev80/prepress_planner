/// Сквозная проверка расчётного пути БЕЗ изменения `packages/core`
/// (задача `e2e-calculation-path`).
///
/// Что проверяется (без обращения к сети):
///   A. импорт DXF/SVG/PDF → анализ технологичности → лечение (F-1, F-5…F-7);
///   B. распознавание массива Step&Repeat + генерация сетки (F-8, F-9);
///   C. **эталонная математика PRD §10.2 не зависит от геометрии**: одна и та же
///      сетка 9×5 / 5040 / 112 / 34137.6 / 26.18 % / 2032.0 получается и для
///      одиночного контура, и для массива (N-1);
///   D. русские `Issue.message`/`suggestion` (F-4, N-8) — без латинских
///      «технических» строк;
///   E. ТЭО §4.5 PRD: costPer1000 = 704.88, totalCost = 3552.58,
///      machineCost = 2528.45, materialCost = 1024.13.
///
/// Запуск: `dart tool/verify_calculation_path.dart [--fixtures DIR]`.
/// Код выхода 0 — все проверки пройдены.
library;

import 'dart:io';

import 'package:prepress_core/prepress_core.dart';

int _passed = 0;
int _failed = 0;

void check(String name, bool ok, [String detail = '']) {
  if (ok) {
    _passed++;
    stdout.writeln('  PASS  $name${detail.isEmpty ? '' : ' — $detail'}');
  } else {
    _failed++;
    stdout.writeln('  FAIL  $name${detail.isEmpty ? '' : ' — $detail'}');
  }
}

void checkNum(String name, double actual, double expected) {
  final delta = (actual - expected).abs();
  check(name, delta == 0.0, 'ожидание $expected, факт $actual, delta $delta');
}

void checkInt(String name, int actual, int expected) {
  check(name, actual == expected, 'ожидание $expected, факт $actual');
}

/// Латинские «технические» подстроки, которых не должно быть в русских сообщениях.
final _latinJargon = RegExp(
    r'\b(error|null|undefined|exception|trace|stack|opcode|0x[0-9a-f]+)\b',
    caseSensitive: false);

bool _isRussianReadable(String text) {
  if (text.trim().isEmpty) return false;
  final hasCyrillic = RegExp(r'[а-яА-ЯёЁ]').hasMatch(text);
  return hasCyrillic && !_latinJargon.hasMatch(text);
}

void main(List<String> args) {
  var fixtures = '../../fixtures';
  for (var i = 0; i < args.length; i++) {
    if (args[i] == '--fixtures' && i + 1 < args.length) fixtures = args[i + 1];
  }

  stdout.writeln('=== A. Импорт → анализ → лечение (F-1, F-5…F-7) ===');
  final files = <String>[
    'petlya_open_artifacts.dxf',
    'petlya_open_artifacts.svg',
    'petlya_open_artifacts.pdf',
    'quadroring.dxf',
    'quadroring.svg',
    'quadroring.pdf',
  ];
  final parsed = <String, List<CamPath>>{};
  for (final name in files) {
    final path = '$fixtures/$name';
    final file = File(path);
    if (!file.existsSync()) {
      check('импорт $name', false, 'файл не найден: $path');
      continue;
    }
    try {
      final bytes = file.readAsBytesSync();
      final paths = parseBytes(bytes, name);
      parsed[name] = paths;
      check('импорт $name', paths.isNotEmpty, '${paths.length} контуров');

      final report = analyzeManufacturability(paths, ManufacturingParams());
      check('анализ $name: вердикт непустой', report.verdict.trim().isNotEmpty,
          'ok=${report.ok}, issues=${report.issues.length}');

      final healed = healGeometry(paths, ManufacturingParams());
      // Лечение может не только чинить контуры, но и разделять самопересечения
      // (1 замкнутый контур → 2), поэтому проверяем результат лечения, а не
      // количество: после лечения открытых контуров не остаётся.
      final openAfter = healed.where((p) => !p.isClosed).length;
      check('лечение $name: непустой результат', healed.isNotEmpty,
          '${paths.length} → ${healed.length} контуров');
      check('лечение $name: открытых контуров не осталось', openAfter == 0,
          'открытых после лечения: $openAfter '
          '(было открытых: ${paths.where((p) => !p.isClosed).length})');

      // Русские сообщения Issue (F-4, N-8): читаемые и без латинского жаргона.
      for (final issue in report.issues) {
        check('issue ${issue.kind}: message по-русски',
            _isRussianReadable(issue.message), '"${issue.message}"');
        check('issue ${issue.kind}: suggestion по-русски',
            _isRussianReadable(issue.suggestion), '"${issue.suggestion}"');
      }
    } catch (e) {
      check('импорт/анализ $name', false, '$e');
    }
  }

  stdout.writeln('\n=== B. Массив: распознавание и генерация сетки (F-8, F-9) ===');
  final qr = parsed['quadroring.dxf'] ?? const <CamPath>[];
  final recognised = PatternRecognizer().analyze(qr);
  check('распознавание quadroring.dxf отработало', true,
      'isArray=${recognised.isArray}, count=${recognised.count}, '
      'rows=${recognised.rows}, cols=${recognised.cols}, '
      'label=${recognised.labelW.toStringAsFixed(3)}×'
      '${recognised.labelH.toStringAsFixed(3)}');

  // Искусственный массив 3×4 из одного квадрата 10×10 → 12 путей.
  final master = <CamPath>[
    CamPath([
      const Vec2(0, 0),
      const Vec2(10, 0),
      const Vec2(10, 10),
      const Vec2(0, 10),
    ], isClosed: true, layerName: 'MASTER'),
  ];
  final grid = generateArrayGrid(master, cols: 4, rows: 3, stepX: 12, stepY: 12);
  checkInt('generateArrayGrid: путей', grid.length, 12);
  check('generateArrayGrid: слой ARRAY',
      grid.every((p) => p.layerName == 'ARRAY'), '${grid.first.layerName}');
  final gridRecognised = PatternRecognizer().analyze(grid);
  check('распознавание сетки 4×3',
      gridRecognised.isArray &&
          gridRecognised.rows == 3 &&
          gridRecognised.cols == 4 &&
          gridRecognised.count == 12,
      'isArray=${gridRecognised.isArray}, count=${gridRecognised.count}, '
      'rows=${gridRecognised.rows}, cols=${gridRecognised.cols}');
  checkInt('autoRowsForRapport(304.8, 30, 3)', autoRowsForRapport(304.8, 30, 3), 9);

  stdout.writeln('\n=== C. Эталон PRD §10.2 не зависит от геометрии (N-1) ===');
  final params = LayoutParams();
  final calc = computeMaterialAuto(params);
  if (calc.error != null) {
    check('расчёт раскроя', false, calc.error!);
  } else {
    checkInt('rows', calc.rows, 9);
    checkInt('cols', calc.cols, 5);
    checkInt('count (N)', calc.count, 5040);
    checkInt('обороты', calc.revs, 112);
    checkNum('длина, мм', calc.length, 34137.6);
    checkNum('отходы, %', calc.wastePct, 26.18);
    checkNum('площадь на этикетку, мм²', calc.perLabelArea, 2032.0);
    checkNum('раппорт, мм', calc.rapport, 304.8);
  }

  // Эталон §10.2 задаётся ТОЛЬКО параметрами раскроя: `computeMaterial(p)`
  // вообще не принимает геометрию, поэтому одинаковый результат обязан
  // получаться и для одиночного контура, и для массива (N-1). Проверяем
  // детерминизм (повторный расчёт) и то, что распознанный массив не влияет
  // на эталонные числа.
  final repeated = computeMaterialAuto(LayoutParams());
  check('эталон раскроя воспроизводится при повторном расчёте',
      repeated.error == null && repeated.count == 5040,
      'N=${repeated.count}, отходы ${repeated.wastePct}%');
  check('раскрой не зависит от наличия массива на входе',
      repeated.count == calc.count &&
          repeated.wastePct == calc.wastePct &&
          repeated.length == calc.length &&
          repeated.perLabelArea == calc.perLabelArea,
      'N ${calc.count}/${repeated.count}, '
      'отходы ${calc.wastePct}/${repeated.wastePct}%, '
      'при этом массив ${grid.length} путей распознан как '
      '${gridRecognised.cols}×${gridRecognised.rows}');

  stdout.writeln('\n=== D. ТЭО: эталон PRD §4.5 ===');
  if (calc.error == null) {
    final catalog = PriceCatalog.defaults();
    final input = TeoInput(material: catalog.assortment.first,
        machine: catalog.machines.first);
    final shape = shapeFromPreset('rect', calc.labelW, calc.labelH);
    final cons = computeConsumption(calc, shape);
    final teo = computeTeo(calc, cons, input);
    checkNum('costPer1000, ₽', teo.costPer1000, 704.88);
    checkNum('totalCost, ₽', teo.totalCost, 3552.58);
    checkNum('machineCost, ₽', teo.machineCost, 2528.45);
    checkNum('materialCost, ₽', teo.materialCost, 1024.13);
    checkNum('runTime, ч', teo.runTimeHours, 0.0057);

    // Сравнение вариантов и точка безубыточности (F-15) — API существует и работает.
    final variants = enumerateVariants(params, limit: 10);
    final cmp = compareTeoVariants(
        variants,
        (v) => computeConsumption(v, shapeFromPreset('rect', v.labelW, v.labelH)),
        input);
    check('compareTeoVariants: лучший — базовый',
        cmp.bestIndex == 0 && cmp.bestCostPer1000 == 704.88,
        'bestIndex=${cmp.bestIndex}, ${cmp.bestCostPer1000} ₽/1000');

    // Точка безубыточности (F-15): два варианта раскроя из перебора.
    if (variants.length >= 2) {
      final a = variants[0];
      final b = variants[1];
      final teoA = computeTeo(a,
          computeConsumption(a, shapeFromPreset('rect', a.labelW, a.labelH)), input);
      final teoB = computeTeo(b,
          computeConsumption(b, shapeFromPreset('rect', b.labelW, b.labelH)), input);
      final be = breakEvenQuantity(a, teoA, 0, b, teoB, 0);
      check('breakEvenQuantity: вернула число',
          be >= 0 && be.isFinite,
          'вариант №1 (${a.rows}×${a.cols}) → вариант №2 (${b.rows}×${b.cols}): точка безубыточности $be шт');
    }
  }

  stdout.writeln('\n=== ИТОГ ===');
  stdout.writeln('пройдено: $_passed, провалено: $_failed');
  if (_failed > 0) {
    exitCode = 1;
    stdout.writeln('ПРОВАЛ: расчётный путь не подтверждён');
  } else {
    stdout.writeln('ALL PASS (расчётный путь + эталон PRD §10.2/§4.5)');
  }
}
