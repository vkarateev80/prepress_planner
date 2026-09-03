/// Экран «Раскрой/Расход»: форма, результат, варианты, превью.
library;

import 'dart:isolate';

import 'package:flutter/material.dart';
import 'package:prepress_core/prepress_core.dart';

import '../../license/entitlement_store.dart';
import '../projects/project.dart';
import '../widgets/params_form.dart';
import '../widgets/variants_table.dart';

class LayoutScreen extends StatefulWidget {
  final Project? project;
  final ValueChanged<Project> onChange;
  final FeatureGate? gate;
  final VoidCallback? onNeedPro;
  const LayoutScreen(
      {super.key,
      required this.project,
      required this.onChange,
      this.gate,
      this.onNeedPro});

  @override
  State<LayoutScreen> createState() => _LayoutScreenState();
}

class _LayoutScreenState extends State<LayoutScreen> {
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final project = widget.project;
    if (project == null) {
      return const Center(
          child: Text('Создайте или откройте проект на вкладке «Проекты».'));
    }
    final calc = project.calc;
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Text('Параметры раскроя',
            style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        ParamsForm(
          initial: project.params,
          onChanged: (params) => _compute(project, params),
        ),
        if (_busy) const LinearProgressIndicator(),
        if (calc != null && calc.error == null) ...[
          const Divider(),
          Text('Результат расхода',
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          _resultGrid(calc),
          const Divider(),
          Row(
            children: [
              Text('Варианты раскроя (${project.variants.length})',
                  style: Theme.of(context).textTheme.titleMedium),
              const Spacer(),
              FilledButton.icon(
                  onPressed: _busy
                      ? null
                      : () => _enumerate(project, project.params),
                  icon: const Icon(Icons.sort),
                  label: const Text('Перебрать варианты')),
            ],
          ),
          const SizedBox(height: 8),
          if (project.variants.isNotEmpty)
            VariantsTable(
              variants: project.variants,
              selectedIndex: project.selectedVariantIndex,
              onSelect: (i) => _selectVariant(project, i),
            ),
        ] else if (calc != null)
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text('Ошибка расчёта: ${calc.error}',
                style: const TextStyle(color: Colors.red)),
          ),
      ],
    );
  }

  Widget _resultGrid(MaterialResult c) {
    Widget cell(String label, String value) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label,
                style: Theme.of(context).textTheme.bodySmall),
            Text(value,
                style: Theme.of(context).textTheme.titleMedium),
          ],
        );
    return Wrap(
      spacing: 24,
      runSpacing: 12,
      children: [
        cell('Раскладка', '${c.rows} рядов × ${c.cols} колонок'),
        cell('За оборот', '${c.perRev}'),
        cell('Оборотов', '${c.revs}'),
        cell('Этикеток N', '${c.count}'),
        cell('Длина, мм', c.length.toStringAsFixed(1)),
        cell('Отходы, %', '${c.wastePct.toStringAsFixed(2)}'),
        cell('На этикетку, мм²', c.perLabelArea.toStringAsFixed(1)),
        cell('Ширина полотна, мм', c.webWidth.toStringAsFixed(1)),
        cell('Раппорт, мм', c.rapport.toStringAsFixed(2)),
      ],
    );
  }

  Future<void> _compute(Project project, LayoutParams params) async {
    setState(() => _busy = true);
    try {
      final calc = await Isolate.run(() => computeMaterialAuto(params));
      widget.onChange(Project(
        name: project.name,
        inputFile: project.inputFile,
        params: params,
        rawPaths: project.rawPaths,
        healedPaths: project.healedPaths,
        issues: project.issues,
        pattern: project.pattern,
        arrayPaths: project.arrayPaths,
        calc: calc,
        variants: project.variants,
        selectedVariantIndex: project.selectedVariantIndex,
      ));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _enumerate(Project project, LayoutParams params) async {
    final gate = widget.gate;
    if (gate != null && !gate.hasProAccess) {
      widget.onNeedPro?.call();
      return;
    }
    setState(() => _busy = true);
    try {
      final variants = await Isolate.run(() => enumerateVariants(params));
      final calc = variants.isEmpty ? null : variants.first;
      widget.onChange(Project(
        name: project.name,
        inputFile: project.inputFile,
        params: params,
        rawPaths: project.rawPaths,
        healedPaths: project.healedPaths,
        issues: project.issues,
        pattern: project.pattern,
        arrayPaths: project.arrayPaths,
        calc: calc,
        variants: variants,
        selectedVariantIndex: 0,
      ));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _selectVariant(Project project, int i) {
    widget.onChange(Project(
      name: project.name,
      inputFile: project.inputFile,
      params: project.params,
      rawPaths: project.rawPaths,
      healedPaths: project.healedPaths,
      issues: project.issues,
      pattern: project.pattern,
      arrayPaths: project.arrayPaths,
      calc: project.variants[i],
      variants: project.variants,
      selectedVariantIndex: i,
    ));
  }
}
