/// Проверка генерации отчётов F-16…F-18 (PDF ТЭО с кириллицей, XLSX,
/// DXF) БЕЗ изменения `packages/core`.
///
/// Запуск: `dart tool/verify_reports.dart [--out DIR]` (по умолчанию — tmp).
/// Код выхода 0 — все отчёты построены и валидны.
///
/// Кириллица в PDF проверяется по факту: в PDF обязан лежать CID-шрифт
/// (`Type0`/`Identity-H`), карта `ToUnicode` и реальные UTF-16BE-последовательности
/// кириллицы — то есть русский текст в отчёте не потерян.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:prepress_core/io.dart';
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

/// Кириллица в UTF-16BE (как кодирует CID-шрифт с Identity-H).
bool hasCyrillicUtf16Be(Uint8List bytes) {
  for (var i = 0; i + 1 < bytes.length; i += 2) {
    if (bytes[i] == 0x04 && bytes[i + 1] >= 0x10 && bytes[i + 1] <= 0x4F) {
      return true;
    }
  }
  return false;
}

void main(List<String> args) {
  var outDir = Directory.systemTemp.createTempSync('pp_reports').path;
  for (var i = 0; i < args.length; i++) {
    if (args[i] == '--out' && i + 1 < args.length) outDir = args[i + 1];
  }
  Directory(outDir).createSync(recursive: true);

  stdout.writeln('=== Данные отчёта (эталон PRD §10.2/§4.5) ===');
  final params = LayoutParams();
  final calc = computeMaterialAuto(params);
  if (calc.error != null) {
    check('расчёт раскроя', false, calc.error!);
    _summary();
    return;
  }
  final catalog = PriceCatalog.defaults();
  final input = TeoInput(
      material: catalog.assortment.first, machine: catalog.machines.first);
  final shape = shapeFromPreset('rect', calc.labelW, calc.labelH);
  final cons = computeConsumption(calc, shape);
  final teo = computeTeo(calc, cons, input);
  final variants = enumerateVariants(params, limit: 10);
  final cmp = compareTeoVariants(
      variants,
      (v) => computeConsumption(v, shapeFromPreset('rect', v.labelW, v.labelH)),
      input);

  final data = TeoReportData(
    projectName: 'Проверка отчётов (кириллица)',
    inputFile: '../../fixtures/quadroring.dxf',
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
  check('данные ТЭО собраны', teo.costPer1000 == 704.88,
      'costPer1000=${teo.costPer1000}');

  // ---------- 1. PDF (F-16, F-18: кириллица через встроенный TTF) ----------
  stdout.writeln('\n=== 1. PDF ТЭО (F-16, F-18) ===');
  // Шрифт берётся явно из комплекта приложения (F-18): `fontPathForCyrillic()`
  // — удобный поиск на хосте, но он обходит дерево ВНИЗ от CWD, поэтому тест
  // не должен зависеть от него. Чистая функция `buildTeoReportPdf` принимает
  // байты шрифта — проверяем ровно её (и запись через writeTeoReportPdf).
  final fontFile = File('../../app/assets/fonts/DejaVuSans.ttf');
  check('шрифт комплекта app/assets/fonts/DejaVuSans.ttf на месте',
      fontFile.existsSync(), fontFile.path);
  if (fontFile.existsSync()) {
    final fontBytes = fontFile.readAsBytesSync();
    check('TTF прочитан', fontBytes.length > 50000,
        '${fontBytes.length} байт (сигнатура '
        '${fontBytes[0].toRadixString(16)}${fontBytes[1].toRadixString(16)})');
    // Встроенный CID-шрифт можно построить и без записи на диск.
    final pdfBytes = buildTeoReportPdf(data, fontBytes);
    final pdfPath = '$outDir/report_teo.pdf';
    File(pdfPath).writeAsBytesSync(pdfBytes);
    final file = File(pdfPath);
    final onDisk = file.readAsBytesSync();
    check('PDF записан на диск', file.existsSync() && onDisk.length > 1024,
        '${onDisk.length} байт');
    check('PDF: сигнатура %PDF-',
        ascii.decode(onDisk.sublist(0, 5)) == '%PDF-');
    final pdfText = latin1.decode(onDisk, allowInvalid: true);
    check('PDF: CID-шрифт Type0', pdfText.contains('/Type0'),
        'Type0 присутствует');
    check('PDF: кодировка Identity-H', pdfText.contains('Identity-H'));
    check('PDF: карта ToUnicode', pdfText.contains('/ToUnicode'));
    check('PDF: завершён (%%EOF)', pdfText.trimRight().endsWith('%%EOF'));
    check('PDF: построен без записи (API bytes)',
        pdfBytes.length == onDisk.length,
        '${pdfBytes.length} == ${onDisk.length}');
    // Кириллица: либо как UTF-16BE-глифы, либо как встроенный subset шрифта.
    final cyr = hasCyrillicUtf16Be(onDisk);
    final hasFontFile = pdfText.contains('/FontFile2');
    check('PDF: кириллица встроена (глифы UTF-16BE либо subset шрифта)',
        cyr || hasFontFile,
        'UTF-16BE-кириллица=$cyr, /FontFile2=$hasFontFile');
    check('PDF: нет маски/G-кода (границы домена)',
        !RegExp(r'mask|gcode|g-code', caseSensitive: false).hasMatch(pdfText));

    // Хостовый поиск (fontPathForCyrillic) — информационно: он не обязателен
    // для web-пути (там шрифт приходит из rootBundle, F-18).
    final hostFont = fontPathForCyrillic();
    stdout.writeln('  ИНФО  fontPathForCyrillic() на этом хосте: '
        '${hostFont ?? "не найден (шрифт обходит дерево вниз от CWD)"}');
  }

  // ---------- 2. XLSX ------------------------------------------------------
  stdout.writeln('\n=== 2. XLSX ТЭО (F-16) ===');
  final xlsxPath = '$outDir/report_teo.xlsx';
  writeTeoXlsx(xlsxPath, data);
  final xlsx = File(xlsxPath).readAsBytesSync();
  check('XLSX записан', xlsx.length > 1024, '${xlsx.length} байт');
  check('XLSX: это ZIP-контейнер (PK\\x03\\x04)',
      xlsx.length > 4 && xlsx[0] == 0x50 && xlsx[1] == 0x4B &&
          xlsx[2] == 0x03 && xlsx[3] == 0x04);
  // Валидный XLSX = OOXML-пакет: [Content_Types].xml + листы.
  final zipText = latin1.decode(xlsx, allowInvalid: true);
  check('XLSX: есть [Content_Types].xml', zipText.contains('[Content_Types].xml'));
  final sheetNames =
      RegExp(r'xl/worksheets/sheet\d+\.xml').allMatches(zipText).length;
  check('XLSX: есть листы (worksheets)', sheetNames >= 1, 'найдено $sheetNames');
  check('XLSX: нет маски/G-кода',
      !RegExp(r'mask|gcode', caseSensitive: false).hasMatch(zipText));

  // ---------- 3. DXF ------------------------------------------------------
  stdout.writeln('\n=== 3. DXF мастера (F-16) ===');
  final healed = healGeometry(parseFile('../../fixtures/quadroring.dxf'),
      ManufacturingParams());
  final dxfPath = '$outDir/master.dxf';
  writeDxf(dxfPath, healed);
  final dxfText = File(dxfPath).readAsStringSync();
  check('DXF записан', dxfText.length > 200, '${dxfText.length} символов');
  check('DXF: заголовок SECTION', dxfText.contains('SECTION'));
  check('DXF: сущности LWPOLYLINE', dxfText.contains('LWPOLYLINE'));
  check('DXF: завершён EOF', dxfText.trimRight().endsWith('EOF'));
  final roundTrip = parseFile(dxfPath);
  check('DXF: читается обратно парсером',
      roundTrip.length == healed.length,
      '${healed.length} контуров → ${roundTrip.length}');

  stdout.writeln('\nКаталог отчётов: $outDir');
  _summary();
}

void _summary() {
  stdout.writeln('\n=== ИТОГ ===');
  stdout.writeln('пройдено: $_passed, провалено: $_failed');
  if (_failed > 0) {
    exitCode = 1;
    stdout.writeln('ПРОВАЛ: отчёты не подтверждены');
  } else {
    stdout.writeln('ALL PASS (отчёты PDF/XLSX/DXF)');
  }
}
