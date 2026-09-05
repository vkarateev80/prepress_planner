// E2E-сценарий домена (аг.14): quadroring.dxf → анализ → лечение →
// массив → расход (эталон 50×30) → ТЭО → отчёты. Выход 0 = успех.
import 'dart:io';

import '../lib/prepress_core.dart';
import '../lib/io.dart';

String fx(String name) => '../../fixtures/$name';

void main() {
  final outDir = Directory.systemTemp.createTempSync('pp_e2e');
  try {
    // 1. Парсинг.
    final raw = parseFile(fx('quadroring.dxf'));
    print('1. Парсинг: ${raw.length} контуров');

    // 2. Анализ технологичности.
    final report = analyzeManufacturability(raw, ManufacturingParams());
    print('2. Анализ: ok=${report.ok}, issues=${report.issues.length}, '
        'вердикт: ${report.verdict}');

    // 3. Лечение.
    final healed = healGeometry(raw, ManufacturingParams());
    print('3. Лечение: ${healed.length} контуров, '
        'замкнуто: ${healed.where((p) => p.isClosed).length}');

    // 4. Массив.
    final pattern = PatternRecognizer().analyze(healed);
    print('4. Массив: isArray=${pattern.isArray}, count=${pattern.count}, '
        'этикетка ${pattern.labelW.toStringAsFixed(2)}×'
        '${pattern.labelH.toStringAsFixed(2)}');

    // 5. Расход: эталон 50×30.
    final params = LayoutParams();
    final calc = computeMaterialAuto(params);
    if (calc.error != null) {
      stderr.writeln('ОШИБКА расчёта: ${calc.error}');
      exitCode = 1;
      return;
    }
    print('5. Расход: ${calc.rows}×${calc.cols}, N=${calc.count}, '
        'оборотов=${calc.revs}, длина=${calc.length}, '
        'отходы=${calc.wastePct}%, на этикетку=${calc.perLabelArea}');
    if (calc.rows != 9 ||
        calc.cols != 5 ||
        calc.count != 5040 ||
        (calc.wastePct - 26.18).abs() > 0.05 ||
        (calc.perLabelArea - 2032.0).abs() > 0.05) {
      stderr.writeln('ОШИБКА: эталон расхода не сошёлся');
      exitCode = 1;
      return;
    }

    // 6. Shape + расход по форме.
    final shape = shapeFromPreset('rect', calc.labelW, calc.labelH);
    final cons = computeConsumption(calc, shape);
    print('6. Расход по форме: использовано ${cons.usedAreaMm2} мм², '
        'отходы ${cons.wastePct.toStringAsFixed(2)}%');

    // 7. Варианты + ТЭО.
    final variants = enumerateVariants(params, limit: 10);
    final catalog = PriceCatalog.defaults();
    final input = TeoInput(
        material: catalog.assortment.first, machine: catalog.machines.first);
    final teo = computeTeo(calc, cons, input);
    final cmp = compareTeoVariants(
        variants,
        (v) => computeConsumption(
            v, shapeFromPreset('rect', v.labelW, v.labelH)),
        input);
    print('7. ТЭО: costPer1000=${teo.costPer1000}, '
        'лучший вариант #${cmp.bestIndex + 1} '
        '(${cmp.bestCostPer1000} ₽/1000), экономия '
        '${cmp.savingsPer1000} ₽/1000');

    // 8. Отчёты.
    final reportData = TeoReportData(
      projectName: 'E2E-проверка',
      inputFile: fx('quadroring.dxf'),
      params: params,
      shape: shape,
      calc: calc,
      consumption: cons,
      teo: teo,
      comparison: cmp,
      material: catalog.assortment.first,
      machine: catalog.machines.first,
      workTime: catalog.workTime,
      currency: catalog.currency,
      date: DateTime.now(),
    );
    writeTeoXlsx('${outDir.path}/e2e.xlsx', reportData);
    writeTeoReportPdf('${outDir.path}/e2e.pdf', reportData);
    writeDxf('${outDir.path}/e2e_master.dxf', healed);
    print('8. Отчёты: ${outDir.path}');
    final pdf = File('${outDir.path}/e2e.pdf');
    if (!pdf.existsSync() || pdf.lengthSync() < 1024) {
      stderr.writeln('ОШИБКА: PDF не создан или пуст');
      exitCode = 1;
      return;
    }
    print('E2E OK');
  } finally {
    outDir.deleteSync(recursive: true);
  }
}
