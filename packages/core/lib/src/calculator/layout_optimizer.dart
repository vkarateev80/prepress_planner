/// Оптимизация расхода материала — порт 1:1 `cam_material/src/calculator/optimizer.py`.
///
/// Перебирает варианты раскроя:
///   - ориентация этикетки (обычная / повёрнутая на 90°);
///   - число рядов r (с условием сходимости шва: step = rapport / r);
///   - число колонок c (ограничено шириной цилиндра и полотна).
///
/// Критерий сортировки: минимальная площадь на этикетку (мм²/шт),
/// при равенстве — меньший процент отходов. Лучший — первый.
library;

import '../model/params.dart';
import 'material.dart';

/// Полный перебор вариантов раскроя. Возвращает список результатов
/// [computeMaterial], отсортированный по критерию (лучший первый).
///
/// [limit] ограничивает число возвращаемых вариантов (по умолчанию 50);
/// 0 — без ограничения (поведение Python-эталона при limit=None/0).
List<MaterialResult> enumerateVariants(LayoutParams p, {int limit = 50}) {
  final rapport = computeRapportValue(p.zTeeth, p.cp, manual: p.rapportManual);
  if (rapport <= 0) return const [];

  final effectiveWidth =
      p.cylWidth < p.webWidth ? p.cylWidth : p.webWidth;
  final variants = <MaterialResult>[];

  for (final rotated in [false, true]) {
    final lw = rotated ? p.labelH : p.labelW;
    final lh = rotated ? p.labelW : p.labelH;
    for (final rows in rowCandidates(rapport, lh, p.minGap)) {
      for (final cols in colCandidates(effectiveWidth, lw, p.gapX)) {
        final res = computeMaterial(p, rows: rows, cols: cols, rotated: rotated);
        if (res.error == null) variants.add(res);
      }
    }
  }

  // Стабильная сортировка по (perLabelArea, wastePct): сортировка через
  // индексы с финальным сравнением по исходному порядку — детерминированно
  // воспроизводит поведение стабильного sort() Python при равенстве ключей.
  final order = List<int>.generate(variants.length, (i) => i);
  order.sort((i, j) {
    final a = variants[i];
    final b = variants[j];
    final c = a.perLabelArea.compareTo(b.perLabelArea);
    if (c != 0) return c;
    final w = a.wastePct.compareTo(b.wastePct);
    if (w != 0) return w;
    return i.compareTo(j);
  });
  final sorted = [for (final i in order) variants[i]];

  if (limit != 0 && sorted.length > limit) {
    return sorted.sublist(0, limit);
  }
  return sorted;
}
