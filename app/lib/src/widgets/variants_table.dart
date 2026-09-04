/// Таблица вариантов раскроя (выбор строки).
library;

import 'package:flutter/material.dart';
import 'package:prepress_core/prepress_core.dart';

class VariantsTable extends StatelessWidget {
  final List<MaterialResult> variants;
  final int selectedIndex;
  final ValueChanged<int> onSelect;
  const VariantsTable(
      {super.key,
      required this.variants,
      required this.selectedIndex,
      required this.onSelect});

  @override
  Widget build(BuildContext context) {
    if (variants.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: Text('Нет вариантов — проверьте параметры.'),
      );
    }
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: DataTable(
        columns: const [
          DataColumn(label: Text('№')),
          DataColumn(label: Text('Сетка')),
          DataColumn(label: Text('Пов.')),
          DataColumn(label: Text('N')),
          DataColumn(label: Text('Длина, м')),
          DataColumn(label: Text('Отходы, %')),
          DataColumn(label: Text('На этикетку, м²')),
        ],
        rows: [
          for (var i = 0; i < variants.length && i < 50; i++)
            DataRow(
              selected: i == selectedIndex,
              onSelectChanged: (_) => onSelect(i),
              cells: [
                DataCell(Text('${i + 1}')),
                DataCell(Text('${variants[i].rows}×${variants[i].cols}')),
                DataCell(Text(variants[i].rotated ? 'да' : '—')),
                DataCell(Text('${variants[i].count}')),
                DataCell(Text((variants[i].length / 1000).toStringAsFixed(3))),
                DataCell(Text(variants[i].wastePct.toStringAsFixed(2))),
                DataCell(
                    Text((variants[i].perLabelArea / 1e6).toStringAsFixed(6))),
              ],
            ),
        ],
      ),
    );
  }
}
