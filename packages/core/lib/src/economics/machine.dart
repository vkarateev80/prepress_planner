/// Машины и рабочее время (статьи затрат «машино-час» и «смена», агент 07).
library;

/// Печатная/отделочная машина.
///
/// Производительность задаётся одним из двух способов:
///   [speedMetersPerMin] — рабочая скорость печати, м/мин;
///   [labelsPerHour]     — производительность, этикеток/ч.
/// Если заданы обе — приоритет у [speedMetersPerMin] (см. computeTeo).
class Machine {
  final String id;
  final String name;
  final double ratePerHour; // ставка машино-часа, ₽/ч
  final double? speedMetersPerMin; // рабочая скорость печати, м/мин
  final int? labelsPerHour; // …или производительность, этикеток/ч
  final double setupTimeHours; // переналадка на заказ, ч

  const Machine({
    required this.id,
    required this.name,
    required this.ratePerHour,
    this.speedMetersPerMin,
    this.labelsPerHour,
    this.setupTimeHours = 0,
  });
}

/// Рабочее время предприятия.
class WorkTime {
  final double hoursPerShift; // часов в смене
  final int shiftsPerDay; // смен в сутки

  const WorkTime({this.hoursPerShift = 8, this.shiftsPerDay = 1});
}
