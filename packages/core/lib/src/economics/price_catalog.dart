/// JSON-каталог статей затрат: сортамент, машины, рабочее время, валюта
/// (агент 07). Сериализация через `dart:convert` (Map → JSON строка — на
/// стороне потребителя; здесь — toJson/fromJson).
///
/// Имена полей в JSON — английские; nullable-поля (minOrderM2,
/// speedMetersPerMin, labelsPerHour) отсутствуют в JSON при null.
library;

import 'assortment.dart';
import 'machine.dart';

/// Каталог цен: исходные статьи затрат для расчёта ТЭО.
class PriceCatalog {
  final List<AssortmentItem> assortment;
  final List<Machine> machines;
  final WorkTime workTime;
  final String currency; // '₽'

  const PriceCatalog({
    required this.assortment,
    required this.machines,
    this.workTime = const WorkTime(),
    this.currency = '₽',
  });

  Map<String, dynamic> toJson() {
    return {
      'currency': currency,
      'workTime': {
        'hoursPerShift': workTime.hoursPerShift,
        'shiftsPerDay': workTime.shiftsPerDay,
      },
      'assortment': [
        for (final a in assortment)
          {
            'id': a.id,
            'name': a.name,
            'pricePerM2': a.pricePerM2,
            if (a.minOrderM2 != null) 'minOrderM2': a.minOrderM2,
          }
      ],
      'machines': [
        for (final m in machines)
          {
            'id': m.id,
            'name': m.name,
            'ratePerHour': m.ratePerHour,
            if (m.speedMetersPerMin != null)
              'speedMetersPerMin': m.speedMetersPerMin,
            if (m.labelsPerHour != null) 'labelsPerHour': m.labelsPerHour,
            'setupTimeHours': m.setupTimeHours,
            'setupMaterialMeters': m.setupMaterialMeters,
          }
      ],
    };
  }

  factory PriceCatalog.fromJson(Map<String, dynamic> json) {
    final assortment = <AssortmentItem>[];
    final rawAss = json['assortment'];
    if (rawAss is List) {
      for (final e in rawAss) {
        if (e is! Map) continue;
        final m = Map<String, dynamic>.from(e);
        assortment.add(AssortmentItem(
          id: m['id'] as String? ?? '',
          name: m['name'] as String? ?? '',
          pricePerM2: (m['pricePerM2'] as num?)?.toDouble() ?? 0.0,
          minOrderM2: (m['minOrderM2'] as num?)?.toDouble(),
        ));
      }
    }

    final machines = <Machine>[];
    final rawMac = json['machines'];
    if (rawMac is List) {
      for (final e in rawMac) {
        if (e is! Map) continue;
        final m = Map<String, dynamic>.from(e);
        machines.add(Machine(
          id: m['id'] as String? ?? '',
          name: m['name'] as String? ?? '',
          ratePerHour: (m['ratePerHour'] as num?)?.toDouble() ?? 0.0,
          speedMetersPerMin: (m['speedMetersPerMin'] as num?)?.toDouble(),
          labelsPerHour: (m['labelsPerHour'] as num?)?.toInt(),
          setupTimeHours: (m['setupTimeHours'] as num?)?.toDouble() ?? 0.0,
          setupMaterialMeters:
              (m['setupMaterialMeters'] as num?)?.toDouble() ?? 0.0,
        ));
      }
    }

    var hoursPerShift = 8.0;
    var shiftsPerDay = 1;
    final rawWt = json['workTime'];
    if (rawWt is Map) {
      final wt = Map<String, dynamic>.from(rawWt);
      hoursPerShift = (wt['hoursPerShift'] as num?)?.toDouble() ?? 8.0;
      shiftsPerDay = (wt['shiftsPerDay'] as num?)?.toInt() ?? 1;
    }

    return PriceCatalog(
      assortment: assortment,
      machines: machines,
      workTime: WorkTime(hoursPerShift: hoursPerShift, shiftsPerDay: shiftsPerDay),
      currency: json['currency'] as String? ?? '₽',
    );
  }

  /// Образец каталога: 3 сортамента и 2 машины с примерными ценами
  /// (в name каждого — пометка «(пример)»).
  factory PriceCatalog.defaults() => const PriceCatalog(
        assortment: [
          AssortmentItem(
            id: 'paper-sa-80',
            name: 'Бумага самоклеящаяся 80 г/м² (пример)',
            pricePerM2: 100.0,
            minOrderM2: 500.0,
          ),
          AssortmentItem(
            id: 'film-pet-50',
            name: 'Плёнка ПЭТ 50 мкм (пример)',
            pricePerM2: 250.0,
            minOrderM2: 300.0,
          ),
          AssortmentItem(
            id: 'film-pp-40',
            name: 'Плёнка ПП 40 мкм (пример)',
            pricePerM2: 180.0,
            minOrderM2: 300.0,
          ),
        ],
        machines: [
          Machine(
            id: 'flexo-300',
            name: 'Флексопечать, ширина 300 мм (пример)',
            ratePerHour: 5000.0,
            speedMetersPerMin: 100.0,
            setupTimeHours: 0.5,
          ),
          Machine(
            id: 'digital-label',
            name: 'Цифровая печать этикеток (пример)',
            ratePerHour: 9000.0,
            labelsPerHour: 2500,
            setupTimeHours: 0.1,
          ),
        ],
      );
}
