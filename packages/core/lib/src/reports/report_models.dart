/// Входные данные отчёта ТЭО (агент 08): всё, что нужно генераторам
/// PDF/XLSX/DXF, собранное из расчётов аг.05–07.
library;

import '../model/params.dart';
import '../calculator/material.dart';
import '../calculator/shape.dart';
import '../calculator/consumption.dart';
import '../economics/assortment.dart';
import '../economics/machine.dart';
import '../economics/teo.dart';

/// Полный набор данных для отчётов о технико-экономическом обосновании.
class TeoReportData {
  final String projectName;
  final String inputFile; // исходный файл задания (DXF/PDF/…), как введён
  final LayoutParams params;
  final LabelShape shape; // форма этикетки (выбранный вариант)
  final MaterialResult calc; // выбранный вариант раскроя (аг.05)
  final Consumption consumption; // свод расхода по фактической форме
  final TeoResult teo; // ТЭО выбранного варианта
  final TeoComparison comparison; // сравнение вариантов
  final AssortmentItem material; // сортамент (статья «материал»)
  final Machine machine; // машина (статья «машино-час»)
  final WorkTime workTime;
  final String currency; // '₽' (как в PriceCatalog)
  final DateTime date; // дата/время отчёта

  const TeoReportData({
    required this.projectName,
    required this.inputFile,
    required this.params,
    required this.shape,
    required this.calc,
    required this.consumption,
    required this.teo,
    required this.comparison,
    required this.material,
    required this.machine,
    required this.workTime,
    required this.currency,
    required this.date,
  });
}
