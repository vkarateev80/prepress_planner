/// Сортамент: материалы полотна со статьёй затрат «материал» (агент 07).
///
/// Цены — за квадратный метр (₽/м²); [minOrderM2] — минимальный заказ
/// в квадратных метрах (null — ограничения нет).
library;

/// Единица сортамента.
class AssortmentItem {
  final String id;
  final String name; // «Бумага самоклеящаяся 80 г/м²», «Плёнка ПЭТ 50 мкм»…
  final double pricePerM2; // ₽/м²
  final double? minOrderM2; // мин. заказ, м²; null — нет ограничения

  const AssortmentItem({
    required this.id,
    required this.name,
    required this.pricePerM2,
    this.minOrderM2,
  });
}
