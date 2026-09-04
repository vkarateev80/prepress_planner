/// Сборка книги XLSX из [TeoReportData]: листы «Расчёт», «ТЭО», «Варианты».
library;

import 'dart:io';
import 'dart:convert';

import 'xlsx_writer.dart';
import 'report_models.dart';

// ============================================================
// XML-части пакета
// ============================================================

String _contentTypes() {
  return '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
      '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
      '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
      '<Default Extension="xml" ContentType="application/xml"/>'
      '<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>'
      '<Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>'
      '<Override PartName="/xl/worksheets/sheet2.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>'
      '<Override PartName="/xl/worksheets/sheet3.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>'
      '</Types>';
}

String _rootRels() {
  return '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
      '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
      '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>'
      '</Relationships>';
}

String _workbookXml() {
  return '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
      '<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" '
      'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">'
      '<sheets>'
      '<sheet name="Расчёт" sheetId="1" r:id="rId1"/>'
      '<sheet name="ТЭО" sheetId="2" r:id="rId2"/>'
      '<sheet name="Варианты" sheetId="3" r:id="rId3"/>'
      '</sheets>'
      '</workbook>';
}

String _workbookRels() {
  return '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
      '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
      '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>'
      '<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet2.xml"/>'
      '<Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet3.xml"/>'
      '</Relationships>';
}

// ============================================================
// Листы
// ============================================================

/// Ячейка листа: String → inline-строка, num → число.
typedef _Cell = Object;

String _sheetXml(List<List<_Cell>> rows) {
  final sb = StringBuffer()
    ..write('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n')
    ..write('<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">')
    ..write('<sheetData>');
  for (var r = 0; r < rows.length; r++) {
    sb.write('<row r="${r + 1}">');
    final cells = rows[r];
    for (var c = 0; c < cells.length; c++) {
      final v = cells[c];
      if (v is String) {
        sb.write(cellString(r + 1, c + 1, v));
      } else if (v is num) {
        sb.write(cellNumber(r + 1, c + 1, v));
      }
    }
    sb.write('</row>');
  }
  sb.write('</sheetData></worksheet>');
  return sb.toString();
}

String _shapeName(String kind) {
  switch (kind) {
    case 'rect':
      return 'прямоугольник';
    case 'roundRect':
      return 'прямоугольник со скруглением';
    case 'circle':
      return 'круг';
    case 'ellipse':
      return 'эллипс';
    case 'polygon':
      return 'многоугольник';
    default:
      return kind;
  }
}

String _date(DateTime d) {
  String p(int x) => x.toString().padLeft(2, '0');
  return '${p(d.day)}.${p(d.month)}.${d.year} ${p(d.hour)}:${p(d.minute)}';
}

List<List<_Cell>> _sheetRaschet(TeoReportData d) {
  final c = d.calc;
  final rows = <List<_Cell>>[
    ['Проект', d.projectName],
    ['Дата', _date(d.date)],
    ['Файл задания', d.inputFile],
    ['Этикетка W, мм', c.labelW],
    ['Этикетка H, мм', c.labelH],
    ['Форма', _shapeName(d.shape.kind)],
    ['Площадь формы, мм²', d.shape.area],
    ['Заполнение bbox, %', d.shape.efficiency * 100],
    ['Зазор X, мм', c.gapX],
    ['Зазор Y (запрошен), мм', c.gapYRequested],
    ['Зазор Y (факт.), мм', c.gapYActual],
    ['Шестерня Z', d.params.zTeeth],
    ['CP, мм', d.params.cp],
    ['Раппорт, мм', c.rapport],
    ['Цилиндр, мм', d.params.cylWidth],
    ['Полотно, мм', d.params.webWidth],
    ['Режим', d.params.mode],
    ['Ряды', c.rows],
    ['Колонки', c.cols],
    ['Этикеток за оборот', c.perRev],
    ['Оборотов', c.revs],
    ['Этикеток (N)', c.count],
    ['Заказ N', c.countRequested],
    ['Длина полотна, м', c.length / 1000],
    ['Площадь полотна, м²', d.consumption.areaMm2 / 1e6],
    ['Площадь этикеток, м²', d.consumption.usedAreaMm2 / 1e6],
    ['Отходы, %', c.wastePct],
    ['Отходы, м²', d.consumption.wasteMm2 / 1e6],
    ['На этикетку, м²', c.perLabelArea / 1e6],
  ];
  return rows;
}

List<List<_Cell>> _sheetTeo(TeoReportData d) {
  final t = d.teo;
  final m = d.machine;
  final speed = m.speedMetersPerMin;
  return <List<_Cell>>[
    ['Сортамент', d.material.name],
    ['Цена, ${d.currency}/м²', d.material.pricePerM2],
    ['Машина', m.name],
    ['Ставка, ${d.currency}/ч', m.ratePerHour],
    ['Скорость, м/мин',
        speed != null && speed > 0 ? speed : '— (${m.labelsPerHour} шт/ч)'],
    ['Переналадка, ч', m.setupTimeHours],
    ['Машинное время, ч', t.runTimeHours],
    ['Всего времени, ч', t.totalTimeHours],
    ['Стоимость машиночасов, ${d.currency}', t.machineCost],
    ['Стоимость материала, ${d.currency}', t.materialCost],
    ['Занято смен', t.shiftsUsed],
    ['Стоимость смен, ${d.currency}', t.shiftCost],
    ['Оснастка, ${d.currency}', t.toolingCost],
    ['Наценка, ${d.currency}', t.markupCost],
    ['ИТОГО, ${d.currency}', t.totalCost],
    ['Себестоимость 1000 шт, ${d.currency}', t.costPer1000],
    ['Себестоимость этикетки, ${d.currency}', t.costPerLabel],
    ['Загрузка смены, %', t.shiftLoadPct],
    ['Смена', '${d.workTime.hoursPerShift} ч × ${d.workTime.shiftsPerDay}'],
    ['Валюта', d.currency],
  ];
}

List<List<_Cell>> _sheetVariants(TeoReportData d) {
  final rows = <List<_Cell>>[
    ['№', 'Сетка (R×C)', 'Повёрнут', 'N', 'Отходы, %', 'Длина, м',
        'Себестоимость 1000 шт'],
  ];
  var n = 1;
  for (final (v, t) in d.comparison.variants) {
    rows.add(<_Cell>[
      n,
      '${v.rows}×${v.cols}',
      v.rotated ? 'да' : '—',
      v.count,
      v.wastePct,
      v.length / 1000,
      t.costPer1000,
    ]);
    n++;
  }
  return rows;
}

// ============================================================
// Запись файла
// ============================================================

/// Пишет книгу XLSX (store-zip) из данных отчёта ТЭО.
void writeTeoXlsx(String outPath, TeoReportData data) {
  final entries = <ZipEntry>[
    ZipEntry('[Content_Types].xml', utf8.encode(_contentTypes())),
    ZipEntry('_rels/.rels', utf8.encode(_rootRels())),
    ZipEntry('xl/workbook.xml', utf8.encode(_workbookXml())),
    ZipEntry('xl/_rels/workbook.xml.rels', utf8.encode(_workbookRels())),
    ZipEntry('xl/worksheets/sheet1.xml',
        utf8.encode(_sheetXml(_sheetRaschet(data)))),
    ZipEntry('xl/worksheets/sheet2.xml',
        utf8.encode(_sheetXml(_sheetTeo(data)))),
    ZipEntry('xl/worksheets/sheet3.xml',
        utf8.encode(_sheetXml(_sheetVariants(data)))),
  ];
  File(outPath).writeAsBytesSync(buildZip(entries));
}
