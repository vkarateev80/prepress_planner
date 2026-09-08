/// Экран «Отчёты»: экспорт PDF/XLSX/DXF.
///
/// Генерация — чистыми функциями ядра (buildTeoReportPdf/buildTeoXlsx/
/// buildDxfText) через [heavy]: на desktop в изоляте, на web на главном
/// потоке. Сохранение — платформенное [saveReport]: desktop пишет файлы в
/// выбранную папку, web скачивает браузером. Кириллица PDF — встроенный
/// шрифт assets/fonts/DejaVuSans.ttf (rootBundle).
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:prepress_core/prepress_core.dart';

import '../../platform/env.dart';
import '../../platform/isolates.dart';
import '../../platform/save_out.dart';
import '../logs/app_log.dart';
import '../materials/material_library.dart';
import '../projects/project.dart';

/// Экспорт в тяжелом вызове через топ-левел функции: замыкание создаётся в
/// своей активации и не захватывает состояние экрана (иначе VM делит контекст
/// с setState-замыканием, отправка падает как unsendable).

/// Разрешение материала для отчёта: выбранный в библиотеке (по id) или
/// первый из каталога-примера (прежнее поведение).
AssortmentItem _pickMaterial(
    List<AssortmentItem>? materialOptions, String? materialId) {
  if (materialId != null && materialOptions != null) {
    for (final a in materialOptions) {
      if (a.id == materialId) return a;
    }
  }
  return PriceCatalog.defaults().assortment.first;
}

TeoReportData _buildReportData(Project project,
    {List<AssortmentItem>? materialOptions, String? materialId}) {
  final calc = project.calc!;
  final shape = shapeFromPreset('rect', calc.labelW, calc.labelH);
  final cons = computeConsumption(calc, shape);
  final material =
      _pickMaterial(materialOptions, materialId);
  final machine = PriceCatalog.defaults().machines.first;
  final input = TeoInput(material: material, machine: machine);
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
    material: material,
    machine: machine,
    workTime: PriceCatalog.defaults().workTime,
    currency: PriceCatalog.defaults().currency,
    date: DateTime.now(),
  );
}

Future<Uint8List> _buildPdfBytes(Project project, Uint8List fontBytes,
        {List<AssortmentItem>? materialOptions, String? materialId}) =>
    heavy(() => buildTeoReportPdf(
        _buildReportData(project,
            materialOptions: materialOptions, materialId: materialId),
        fontBytes));

Future<Uint8List> _buildXlsxBytes(Project project,
        {List<AssortmentItem>? materialOptions, String? materialId}) =>
    heavy(() => buildTeoXlsx(_buildReportData(project,
        materialOptions: materialOptions, materialId: materialId)));

Future<String> _buildMasterDxfText(Project project) =>
    heavy(() => buildDxfText(project.healedPaths));

Future<String> _buildArrayDxfText(Project project) =>
    heavy(() => buildDxfText(project.arrayPaths));

class ReportsScreen extends StatefulWidget {
  final Project? project;
  final ProjectStore store;
  final MaterialLibrary? materials;
  const ReportsScreen(
      {super.key, required this.project, required this.store,
      this.materials});

  @override
  State<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends State<ReportsScreen> {
  bool _busy = false;
  String _status = '';

  /// Байты кириллического TTF для PDF (assets/fonts/DejaVuSans.ttf).
  Uint8List? _fontBytes;

  /// Каталог записи на desktop (на web игнорируется — браузерный download).
  String get _outDir =>
      widget.store.directory.isEmpty ? '.' : widget.store.directory;

  /// Запись в журнал приложения (окно «Журнал событий» в шапке).
  void _log(String message, {LogLevel level = LogLevel.info}) =>
      AppLog.instance.record('Отчёты', message, level: level);

  @override
  void initState() {
    super.initState();
    _loadFont();
  }

  Future<void> _loadFont() async {
    try {
      final data =
          await rootBundle.load('assets/fonts/DejaVuSans.ttf');
      final bytes = data.buffer
          .asUint8List(data.offsetInBytes, data.lengthInBytes);
      if (mounted) setState(() => _fontBytes = bytes);
    } catch (e) {
      _log('Не удалось загрузить кириллический шрифт для PDF: $e',
          level: LogLevel.error);
    }
  }

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
        Text(
          isWeb
              ? 'Экспорт: файлы будут скачаны браузером'
              : 'Экспорт в папку: $_outDir',
          style: Theme.of(context).textTheme.bodySmall,
        ),
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
      final font = _fontBytes;
      if (font == null) {
        throw StateError('Кириллический шрифт не загружен (assets/fonts/'
            'DejaVuSans.ttf)');
      }
      final pdf = await _buildPdfBytes(project, font,
          materialOptions: widget.materials?.all,
          materialId: widget.materials?.selectedId);
      final where = await saveReport(_outDir, '04_ТЭО_Отчёт.pdf', pdf);
      if (mounted) {
        setState(() => _status =
            isWeb ? 'Экспортировано: 04_ТЭО_Отчёт.pdf' : 'PDF сохранён: $where');
      }
      _log(isWeb ? 'Экспортировано: 04_ТЭО_Отчёт.pdf' : 'PDF сохранён: $where');
    } catch (e) {
      if (mounted) setState(() => _status = 'Ошибка PDF: $e');
      _log('Ошибка PDF: $e', level: LogLevel.error);
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
      final xlsx = await _buildXlsxBytes(project,
          materialOptions: widget.materials?.all,
          materialId: widget.materials?.selectedId);
      final where = await saveReport(_outDir, '05_Расчёт.xlsx', xlsx);
      if (mounted) {
        setState(() => _status =
            isWeb ? 'Экспортировано: 05_Расчёт.xlsx' : 'XLSX сохранён: $where');
      }
      _log(isWeb ? 'Экспортировано: 05_Расчёт.xlsx' : 'XLSX сохранён: $where');
    } catch (e) {
      if (mounted) setState(() => _status = 'Ошибка XLSX: $e');
      _log('Ошибка XLSX: $e', level: LogLevel.error);
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
      final master = await _buildMasterDxfText(project);
      final names = <String>['02_Вылеченный_Мастер.dxf'];
      await saveReport(_outDir, '02_Вылеченный_Мастер.dxf',
          Uint8List.fromList(utf8.encode(master)));
      if (project.arrayPaths.isNotEmpty) {
        final arr = await _buildArrayDxfText(project);
        names.add('03_Раскрой.dxf');
        await saveReport(_outDir, '03_Раскрой.dxf',
            Uint8List.fromList(utf8.encode(arr)));
      }
      final statusText = isWeb
          ? 'Экспортировано: ${names.join(', ')}'
          : 'DXF сохранены в $_outDir';
      if (mounted) setState(() => _status = statusText);
      _log(statusText);
    } catch (e) {
      if (mounted) setState(() => _status = 'Ошибка DXF: $e');
      _log('Ошибка DXF: $e', level: LogLevel.error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}
