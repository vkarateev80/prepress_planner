/// Экран «Геометрия»: импорт, ошибки, лечение, массив/сетка.
library;

import 'dart:io';
import 'dart:isolate';

import 'package:flutter/material.dart';
import 'package:prepress_core/prepress_core.dart';

import '../projects/project.dart';
import '../widgets/geometry_canvas.dart';

class GeometryScreen extends StatefulWidget {
  final Project? project;
  final ValueChanged<Project> onChange;
  const GeometryScreen({super.key, required this.project, required this.onChange});

  @override
  State<GeometryScreen> createState() => _GeometryScreenState();
}

class _GeometryScreenState extends State<GeometryScreen> {
  final _pathCtrl = TextEditingController();
  bool _busy = false;
  String _status = '';

  Project get p => widget.project ?? Project(name: '');

  @override
  Widget build(BuildContext context) {
    final project = widget.project;
    if (project == null) {
      return const Center(
          child: Text('Создайте или откройте проект на вкладке «Проекты».'));
    }
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(8),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _pathCtrl,
                  decoration: const InputDecoration(
                      labelText: 'Путь к файлу (DXF/SVG/PDF/AI)',
                      border: OutlineInputBorder(),
                      isDense: true),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                  onPressed: _busy ? null : _import,
                  child: const Text('Импорт')),
            ],
          ),
        ),
        if (_busy) const LinearProgressIndicator(),
        if (_status.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Text(_status, style: const TextStyle(color: Colors.blueGrey)),
          ),
        Expanded(
          child: Row(
            children: [
              Expanded(
                flex: 3,
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: GeometryCanvas(
                    paths: project.arrayPaths.isNotEmpty
                        ? project.arrayPaths
                        : (project.healedPaths.isNotEmpty
                            ? project.healedPaths
                            : project.rawPaths),
                    issues: project.issues,
                  ),
                ),
              ),
              Expanded(
                flex: 2,
                child: Column(
                  children: [
                    _actionRow(project),
                    const Divider(),
                    Expanded(child: _issueList(project)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _actionRow(Project project) {
    return Wrap(
      spacing: 8,
      children: [
        ActionChip(
            avatar: const Icon(Icons.healing, size: 18),
            label: const Text('Вылечить всё'),
            onPressed: _busy ? null : () => _heal(project)),
        ActionChip(
            avatar: const Icon(Icons.grid_on, size: 18),
            label: const Text('Распознать массив'),
            onPressed:
                _busy || project.healedPaths.isEmpty ? null : () => _recognize(project)),
        ActionChip(
            avatar: const Icon(Icons.copy_all, size: 18),
            label: const Text('Сгенерировать сетку'),
            onPressed:
                _busy || project.pattern == null ? null : () => _generateGrid(project)),
      ],
    );
  }

  Widget _issueList(Project project) {
    if (project.issues.isEmpty) {
      return const Center(child: Text('Ошибок не найдено.'));
    }
    return ListView.builder(
      itemCount: project.issues.length,
      itemBuilder: (_, i) {
        final issue = project.issues[i];
        final color = switch (issue.severity) {
          'error' => Colors.red,
          'warning' => Colors.orange,
          _ => Colors.amber,
        };
        return ListTile(
          dense: true,
          leading: Icon(Icons.circle, color: color, size: 12),
          title: Text(issue.message, style: const TextStyle(fontSize: 12)),
          subtitle: Text(issue.suggestion,
              style: const TextStyle(fontSize: 11)),
          trailing: issue.fixable
              ? TextButton(
                  onPressed: _busy
                      ? null
                      : () => _fixIssue(project, issue),
                  child: const Text('Исправить'))
              : null,
        );
      },
    );
  }

  Future<void> _import() async {
    final path = _pathCtrl.text.trim();
    if (path.isEmpty || !await File(path).exists()) {
      setState(() => _status = 'Файл не найден: $path');
      return;
    }
    setState(() {
      _busy = true;
      _status = 'Разбор файла…';
    });
    try {
      final paths = await _heavy(() => parseFile(path));
      final issues = await _heavy(() => analyzeManufacturability(
          paths, ManufacturingParams()));
      final updated = Project(
        name: widget.project!.name,
        inputFile: path,
        params: widget.project!.params,
        rawPaths: paths,
        healedPaths: widget.project!.healedPaths,
        issues: issues.issues,
        pattern: widget.project!.pattern,
        arrayPaths: widget.project!.arrayPaths,
        calc: widget.project!.calc,
        variants: widget.project!.variants,
        selectedVariantIndex: widget.project!.selectedVariantIndex,
      );
      setState(() {
        _status =
            'Загружено контуров: ${paths.length}; ошибок: ${issues.issues.length}.';
      });
      widget.onChange(updated);
    } catch (e) {
      setState(() => _status = 'Ошибка: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _heal(Project project) async {
    setState(() {
      _busy = true;
      _status = 'Лечение геометрии…';
    });
    try {
      final healed = await _heavy(
          () => healGeometry(project.rawPaths, ManufacturingParams()));
      final issues = await _heavy(() => analyzeManufacturability(
          healed, ManufacturingParams()));
      widget.onChange(Project(
        name: project.name,
        inputFile: project.inputFile,
        params: project.params,
        rawPaths: project.rawPaths,
        healedPaths: healed,
        issues: issues.issues,
        pattern: project.pattern,
        arrayPaths: project.arrayPaths,
        calc: project.calc,
        variants: project.variants,
        selectedVariantIndex: project.selectedVariantIndex,
      ));
      setState(() => _status = 'Вылечено: ${healed.length} контуров.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _recognize(Project project) async {
    setState(() {
      _busy = true;
      _status = 'Распознавание массива…';
    });
    try {
      final result = await _heavy(
          () => PatternRecognizer().analyze(project.healedPaths));
      final label = result.isArray
          ? 'массив ${result.rows}×${result.cols}, '
              'этикетка ${result.labelW.toStringAsFixed(1)}×'
              '${result.labelH.toStringAsFixed(1)} мм'
          : 'массив не найден (одиночный контур)';
      widget.onChange(Project(
        name: project.name,
        inputFile: project.inputFile,
        params: project.params,
        rawPaths: project.rawPaths,
        healedPaths: project.healedPaths,
        issues: project.issues,
        pattern: result,
        arrayPaths: project.arrayPaths,
        calc: project.calc,
        variants: project.variants,
        selectedVariantIndex: project.selectedVariantIndex,
      ));
      setState(() => _status = 'Распознано: $label.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _generateGrid(Project project) async {
    final pattern = project.pattern!;
    if (!pattern.isArray || pattern.masterPaths.isEmpty) {
      setState(() => _status = 'Массив не распознан — сетку не построить.');
      return;
    }
    setState(() {
      _busy = true;
      _status = 'Генерация сетки…';
    });
    try {
      final grid = await _heavy(() {
        // Из размеров мастера и авто-рядов под раппорт строим сетку.
        final rapport = computeRapportValue(
            project.params.zTeeth, project.params.cp);
        final rows = autoRowsForRapport(rapport, pattern.labelH, project.params.minGap);
        final cols = (project.params.webWidth /
                (pattern.labelW + project.params.gapX))
            .floor();
        final c = cols < 1 ? 1 : cols;
        final r = rows < 1 ? 1 : rows;
        return generateArrayGrid(pattern.masterPaths,
            cols: c,
            rows: r,
            stepX: pattern.labelW + project.params.gapX,
            stepY: pattern.labelH + project.params.gapY);
      });
      widget.onChange(Project(
        name: project.name,
        inputFile: project.inputFile,
        params: project.params,
        rawPaths: project.rawPaths,
        healedPaths: project.healedPaths,
        issues: project.issues,
        pattern: project.pattern,
        arrayPaths: grid,
        calc: project.calc,
        variants: project.variants,
        selectedVariantIndex: project.selectedVariantIndex,
      ));
      setState(() => _status = 'Сетка: ${grid.length} контуров.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _fixIssue(Project project, Issue issue) async {
    setState(() {
      _busy = true;
      _status = 'Применение исправления…';
    });
    try {
      final fixed = await _heavy(() =>
          applyIssueFix(project.rawPaths, issue, ManufacturingParams()));
      widget.onChange(Project(
        name: project.name,
        inputFile: project.inputFile,
        params: project.params,
        rawPaths: fixed,
        healedPaths: project.healedPaths,
        issues: project.issues,
        pattern: project.pattern,
        arrayPaths: project.arrayPaths,
        calc: project.calc,
        variants: project.variants,
        selectedVariantIndex: project.selectedVariantIndex,
      ));
      setState(() => _status = 'Исправление применено.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Тяжёлая синхронная операция в изоляте.
  Future<T> _heavy<T>(T Function() fn) => Isolate.run(fn);
}
