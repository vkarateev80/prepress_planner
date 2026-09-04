/// Экран «Раскрой/Расход»: форма, результат, варианты, превью.
library;

import 'dart:isolate';

import 'package:flutter/material.dart';
import 'package:prepress_core/prepress_core.dart';

import '../../license/entitlement_store.dart';
import '../logs/app_log.dart';
import '../projects/project.dart';
import '../widgets/params_form.dart';
import '../widgets/variants_table.dart';

/// Расчёт раскроя в изоляте. Вызов — только через эти топ-левел функции:
/// замыкание, уходящее в изолят, создаётся в собственной активации и не
/// захватывает `this` (иначе VM кладёт состояние экрана в общий контекст
/// активации с setState-замыканием, и отправка падает как unsendable).
Future<MaterialResult> _isolateComputeAuto(LayoutParams params) =>
    Isolate.run(() => computeMaterialAuto(params));

Future<List<MaterialResult>> _isolateEnumerateVariants(LayoutParams params) =>
    Isolate.run(() => enumerateVariants(params));

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

  /// Запись действия в журнал приложения (окно «Журнал событий» в шапке).
  void _log(String message, {LogLevel level = LogLevel.info}) =>
      AppLog.instance.record('Раскрой', message, level: level);

  /// Номер строки-кандидата: выделяется в таблице, но в расчёт (calc/ТЭО/
  /// отчёты) попадает только после кнопки «Применить».
  int? _pending;

  /// Рейтинг результата расхода среди существующих магнитных валов (Z).
  static const _defaultZList = '24, 28, 32, 36, 40, 48, 56, 64';
  final _zCtrl = TextEditingController(text: _defaultZList);
  List<({int z, MaterialResult calc})> _zRating = [];
  String _zCriterion = 'waste'; // 'waste' | 'length' | 'count'
  bool _zBusy = false;

  @override
  void dispose() {
    _zCtrl.dispose();
    super.dispose();
  }

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
          if (project.variants.isNotEmpty) ...[
            VariantsTable(
              variants: project.variants,
              selectedIndex: _pending ?? project.selectedVariantIndex,
              onSelect: (i) => setState(() => _pending = i),
            ),
            const SizedBox(height: 8),
            _applyBar(project),
          ],
          const Divider(),
          _zRatingSection(project),
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
        cell('Длина, м', (c.length / 1000).toStringAsFixed(3)),
        cell('Отходы, %', '${c.wastePct.toStringAsFixed(2)}'),
        cell('На этикетку, м²', (c.perLabelArea / 1e6).toStringAsFixed(6)),
        cell('Ширина полотна, мм', c.webWidth.toStringAsFixed(1)),
        cell('Раппорт, мм', c.rapport.toStringAsFixed(2)),
      ],
    );
  }

  Future<void> _compute(Project project, LayoutParams params) async {
    setState(() {
      _busy = true;
      _pending = null; // новый расчёт — прежний выбор варианта недействителен
    });
    _log('Расчёт раскроя: этикетка ${params.labelW.toStringAsFixed(2)}×'
        '${params.labelH.toStringAsFixed(2)} мм, зазор X '
        '${params.gapX.toStringAsFixed(2)} / Y ${params.gapY.toStringAsFixed(2)}'
        ' мм, полотно ${params.webWidth.toStringAsFixed(1)} мм, режим '
        '«${params.mode}»');
    try {
      final calc = await _isolateComputeAuto(params);
      if (calc.error != null) {
        _log('Расчёт не выполнен: ${calc.error}', level: LogLevel.error);
      } else {
        _log('Расчёт готов: ${calc.rows}×${calc.cols}, N=${calc.count}, '
            'длина ${(calc.length / 1000).toStringAsFixed(3)} м, отходы '
            '${calc.wastePct.toStringAsFixed(2)}%');
      }
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
      _log('Перебор вариантов: доступно в Pro (Free — 1 проект)',
          level: LogLevel.warning);
      widget.onNeedPro?.call();
      return;
    }
    setState(() {
      _busy = true;
      _pending = null;
    });
    _log('Перебор вариантов раскроя…');
    try {
      final variants = await _isolateEnumerateVariants(params);
      _log('Вариантов найдено: ${variants.length}');
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

  /// Строка «выбранный вариант + Применить» под таблицей вариантов.
  Widget _applyBar(Project project) {
    final sel = (_pending != null && _pending! < project.variants.length)
        ? _pending
        : null;
    final v = sel == null ? null : project.variants[sel];
    return Row(
      children: [
        Expanded(
          child: Text(
            v == null
                ? 'Выберите строку-вариант и нажмите «Применить» — он станет '
                    'расчётным для ТЭО и отчётов.'
                : 'Выбран вариант №${sel! + 1}: ${v.rows}×${v.cols}, '
                    'N=${v.count}, длина ${(v.length / 1000).toStringAsFixed(3)} м, '
                    'отходы ${v.wastePct.toStringAsFixed(2)}%.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
        const SizedBox(width: 8),
        Tooltip(
          message: 'Сделать выбранный вариант расчётным (используется '
              'в ТЭО и при формировании отчётов).',
          child: FilledButton.icon(
            onPressed: sel == null || _busy
                ? null
                : () => _applyVariant(project),
            icon: const Icon(Icons.check),
            label: const Text('Применить'),
          ),
        ),
      ],
    );
  }

  /// «Применить»: выбранная строка становится расчётным вариантом (calc),
  /// её номер запоминается в selectedVariantIndex (для ТЭО и отчётов).
  void _applyVariant(Project project) {
    final i = _pending;
    if (i == null || i < 0 || i >= project.variants.length) return;
    final v = project.variants[i];
    _log('Применён вариант №${i + 1}: ${v.rows}×${v.cols}, '
        'поворот=${v.rotated ? 'да' : 'нет'}, N=${v.count}, длина '
        '${(v.length / 1000).toStringAsFixed(3)} м, отходы '
        '${v.wastePct.toStringAsFixed(2)}%');
    widget.onChange(Project(
      name: project.name,
      inputFile: project.inputFile,
      params: project.params,
      rawPaths: project.rawPaths,
      healedPaths: project.healedPaths,
      issues: project.issues,
      pattern: project.pattern,
      arrayPaths: project.arrayPaths,
      calc: v,
      variants: project.variants,
      selectedVariantIndex: i,
    ));
    setState(() => _pending = null);
  }

  /// Z из текстового поля списка валов (через запятую/пробел), > 0, без
  /// дубликатов; порядок — как ввёл пользователь.
  List<int> _parseZValues() {
    final out = <int>[];
    for (final part in _zCtrl.text.split(RegExp(r'[,\s;]+'))) {
      final z = int.tryParse(part.trim());
      if (z != null && z > 0 && !out.contains(z)) out.add(z);
    }
    return out;
  }

  /// Рассчитать расход для каждого вала Z из списка и сохранить рейтинг.
  Future<void> _rateByCylinders(Project project) async {
    final zs = _parseZValues();
    if (zs.isEmpty) {
      _log('Рейтинг по валам: список Z пуст', level: LogLevel.warning);
      return;
    }
    setState(() {
      _zBusy = true;
      _zRating = [];
    });
    _log('Рейтинг по магнитным валам: перебор Z = $zs');
    final rows = <({int z, MaterialResult calc})>[];
    for (final z in zs) {
      final calc = await _isolateComputeAuto(project.params.copyWith(zTeeth: z));
      if (calc.error != null) {
        _log('Вал Z=$z: расчёт не выполнен (${calc.error})',
            level: LogLevel.warning);
        continue;
      }
      rows.add((z: z, calc: calc));
    }
    if (!mounted) return;
    setState(() {
      _zRating = rows;
      _zBusy = false;
    });
    _log('Рейтинг по валам: рассчитано вариантов ${rows.length}');
  }

  /// Сортировка рейтинга по выбранному критерию.
  List<({int z, MaterialResult calc})> _sortedZRating() {
    final list = List<({int z, MaterialResult calc})>.of(_zRating);
    switch (_zCriterion) {
      case 'length':
        list.sort((a, b) {
          final c = a.calc.length.compareTo(b.calc.length);
          if (c != 0) return c;
          return a.calc.wastePct.compareTo(b.calc.wastePct);
        });
      case 'count':
        list.sort((a, b) {
          final c = b.calc.count.compareTo(a.calc.count);
          if (c != 0) return c;
          return a.calc.wastePct.compareTo(b.calc.wastePct);
        });
      default: // 'waste' — минимальные отходы
        list.sort((a, b) {
          final c = a.calc.wastePct.compareTo(b.calc.wastePct);
          if (c != 0) return c;
          return b.calc.count.compareTo(a.calc.count);
        });
    }
    return list;
  }

  /// Применить выбранный вал (Z) и его расчёт как расчётный для ТЭО/отчётов.
  void _applyZRating(
      Project project, int z, MaterialResult calc) {
    final params = project.params.copyWith(zTeeth: z);
    _log('Применён вал Z=$z: ${calc.rows}×${calc.cols}, N=${calc.count}, '
        'длина ${(calc.length / 1000).toStringAsFixed(3)} м, отходы '
        '${calc.wastePct.toStringAsFixed(2)}%');
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
      variants: const [],
      selectedVariantIndex: 0,
    ));
    if (mounted) setState(() => _pending = null);
  }

  /// Блок «Рейтинг по магнитным валам (Z)»: несколько вариантов
  /// ранжирования результата расхода среди существующих валов.
  Widget _zRatingSection(Project project) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Рейтинг по магнитным валам (Z)',
            style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(
            'Раппорт = Z × CP. Расход считается для каждого вала Z из списка '
            'и ранжируется по выбранному критерию.',
            style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 6),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _zCtrl,
                decoration: const InputDecoration(
                    labelText: 'Магнитные валы, Z (через запятую)',
                    border: OutlineInputBorder(),
                    isDense: true,
                    helperText: 'Пример: 24, 28, 32, 36, 40, 48, 56, 64'),
              ),
            ),
            const SizedBox(width: 8),
            Tooltip(
              message: 'Рассчитать расход для каждого вала Z и построить '
                  'рейтинг.',
              child: FilledButton.icon(
                onPressed:
                    _busy || _zBusy ? null : () => _rateByCylinders(project),
                icon: const Icon(Icons.format_list_numbered),
                label: const Text('Рассчитать рейтинг'),
              ),
            ),
          ],
        ),
        if (_zBusy) ...[
          const SizedBox(height: 6),
          const LinearProgressIndicator(),
        ],
        if (_zRating.isNotEmpty) ...[
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            children: [
              for (final (key, label) in const [
                ('waste', 'По отходам, %'),
                ('length', 'По длине, м'),
                ('count', 'По N этикеток'),
              ])
                ChoiceChip(
                  label: Text(label),
                  selected: _zCriterion == key,
                  onSelected: (_) => setState(() => _zCriterion = key),
                ),
            ],
          ),
          const SizedBox(height: 6),
          _zRatingTable(project),
        ],
      ],
    );
  }

  Widget _zRatingTable(Project project) {
    final rows = _sortedZRating();
    final best = rows.isEmpty ? null : rows.first;
    final curZ = project.params.zTeeth;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (best != null)
          Text(
            'Лучший по «${_zCriterionLabel}»: Z = ${best.z}, '
            'N=${best.calc.count}, длина '
            '${(best.calc.length / 1000).toStringAsFixed(3)} м, отходы '
            '${best.calc.wastePct.toStringAsFixed(2)}%',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        const SizedBox(height: 4),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: DataTable(
            columns: const [
              DataColumn(label: Text('Z')),
              DataColumn(label: Text('Сетка')),
              DataColumn(label: Text('N')),
              DataColumn(label: Text('Длина, м')),
              DataColumn(label: Text('Отходы, %')),
              DataColumn(label: Text('На этикетку, м²')),
            ],
            rows: [
              for (var i = 0; i < rows.length && i < 15; i++)
                DataRow(
                  selected: rows[i].z == curZ,
                  onSelectChanged: (_) => _applyZRating(
                      project, rows[i].z, rows[i].calc),
                  cells: [
                    DataCell(Text('${rows[i].z}'
                        '${i == 0 ? ' ★' : ''}')),
                    DataCell(Text(
                        '${rows[i].calc.rows}×${rows[i].calc.cols}')),
                    DataCell(Text('${rows[i].calc.count}')),
                    DataCell(Text(
                        (rows[i].calc.length / 1000).toStringAsFixed(3))),
                    DataCell(Text(
                        rows[i].calc.wastePct.toStringAsFixed(2))),
                    DataCell(Text((rows[i].calc.perLabelArea / 1e6)
                        .toStringAsFixed(6))),
                  ],
                ),
            ],
          ),
        ),
        const SizedBox(height: 2),
        Text('Строка применяет вал Z (расчётный для ТЭО и отчётов). '
            '★ — лучший по выбранному критерию.',
            style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }

  String get _zCriterionLabel => switch (_zCriterion) {
        'length' => 'длине, м',
        'count' => 'N этикеток',
        _ => 'отходам, %',
      };
}
