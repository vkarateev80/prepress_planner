/// Экран «Отчёты»: экспорт PDF/XLSX/DXF.
library;

import 'dart:isolate';

import 'package:flutter/material.dart';
import 'package:prepress_core/prepress_core.dart';

import '../projects/project.dart';

class ReportsScreen extends StatefulWidget {
  final Project? project;
  final ProjectStore store;
  const ReportsScreen({super.key, required this.project, required this.store});

  @override
  State<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends State<ReportsScreen> {
  bool _busy = false;
  String _status = '';

  String get _outDir =>
      widget.store.directory.isEmpty ? '.' : widget.store.directory;

  @override
  Widget build(BuildContext context) {
    final project = widget.project;
    if (project == null) {
      return const Center(child: Text('Откройте проект.'));
    }
    final calc = project.calc;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('Экспорт в папку: $_outDir',
            style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 16),
        if (_busy) const LinearProgressIndicator(),
        if (_status.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(_status),
        ],
        const SizedBox(height: 8),
        Wrap(
          spacing: 12,
          children: [
            FilledButton.icon(
                onPressed: _busy || calc == null ? null : _exportPdf,
                icon: const Icon(Icons.picture_as_pdf),
                label: const Text('PDF ТЭО')),
            FilledButton.icon(
                onPressed: _busy || calc == null ? null : _exportXlsx,
                icon: const Icon(Icons.table_chart),
                label: const Text('XLSX')),
            FilledButton.icon(
                onPressed: _busy || project.healedPaths.isEmpty
                    ? null
                    : _exportDxf,
                icon: const Icon(Icons.architecture),
                label: const Text('DXF мастера')),
          ],
        ),
      ],
    );
  }

  Future<void> _exportPdf() async {
    final project = widget.project!;
    setState(() {
      _busy = true;
      _status = 'Формирование PDF…';
    });
    try {
      await Isolate.run(() {
        final data = _buildReportData(project);
        writeTeoReportPdf('$_outDir/04_ТЭО_Отчёт.pdf', data);
      });
      setState(() => _status = 'PDF сохранён: $_outDir/04_ТЭО_Отчёт.pdf');
    } catch (e) {
      setState(() => _status = 'Ошибка PDF: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _exportXlsx() async {
    final project = widget.project!;
    setState(() {
      _busy = true;
      _status = 'Формирование XLSX…';
    });
    try {
      await Isolate.run(() {
        final data = _buildReportData(project);
        writeTeoXlsx('$_outDir/05_Расчёт.xlsx', data);
      });
      setState(() => _status = 'XLSX сохранён: $_outDir/05_Расчёт.xlsx');
    } catch (e) {
      setState(() => _status = 'Ошибка XLSX: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _exportDxf() async {
    final project = widget.project!;
    setState(() {
      _busy = true;
      _status = 'Формирование DXF…';
    });
    try {
      await Isolate.run(() {
        writeDxf('$_outDir/02_Вылеченный_Мастер.dxf', project.healedPaths);
        if (project.arrayPaths.isNotEmpty) {
          writeDxf('$_outDir/03_Раскрой.dxf', project.arrayPaths);
        }
      });
      setState(() => _status = 'DXF сохранены в $_outDir');
    } catch (e) {
      setState(() => _status = 'Ошибка DXF: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  TeoReportData _buildReportData(Project project) {
    final calc = project.calc!;
    final shape = shapeFromPreset('rect', calc.labelW, calc.labelH);
    final cons = computeConsumption(calc, shape);
    final catalog = PriceCatalog.defaults();
    final machine = catalog.machines.first;
    final input = TeoInput(material: catalog.assortment.first, machine: machine);
    final teo = computeTeo(calc, cons, input);
    final comparison = compareTeoVariants(
        project.variants.isNotEmpty ? project.variants : [calc],
        (v) => computeConsumption(
            v, shapeFromPreset('rect', v.labelW, v.labelH)),
        input);
    return TeoReportData(
      projectName: project.name,
      inputFile: project.inputFile,
      params: project.params,
      shape: shape,
      calc: calc,
      consumption: cons,
      teo: teo,
      comparison: comparison,
      material: catalog.assortment.first,
      machine: machine,
      workTime: catalog.workTime,
      currency: catalog.currency,
      date: DateTime.now(),
    );
  }
}
