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
import '../projects/project.dart';

/// Экспорт в тяжелом вызове через топ-левел функции: замыкание создаётся в
/// своей активации и не захватывает состояние экрана (иначе VM делит контекст
/// с setState-замыканием, отправка падает как unsendable).

TeoReportData _buildReportData(Project project) {
  final calc = project.calc!;
  final shape = shapeFromPreset('rect', calc.labelW, calc.labelH);
  final cons = computeConsumption(calc, shape);
  final catalog = PriceCatalog.defaults();
  final machine = catalog.machines.first;
  final input =
      TeoInput(material: catalog.assortment.first, machine: machine);
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

Future<Uint8List> _buildPdfBytes(Project project, Uint8List fontBytes) =>
    heavy(() => buildTeoReportPdf(_buildReportData(project), fontBytes));

Future<Uint8List> _buildXlsxBytes(Project project) =>
    heavy(() => buildTeoXlsx(_buildReportData(project)));

Future<String> _buildMasterDxfText(Project project) =>
    heavy(() => buildDxfText(project.healedPaths));

Future<String> _buildArrayDxfText(Project project) =>
    heavy(() => buildDxfText(project.arrayPaths));

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

  /// Байты кириллического TTF для PDF (assets/fonts/DejaVuSans.ttf).
  Uint8List? _fontBytes;

  /// Каталог записи на desktop (на web игнорируется — браузерный download).
  String get _outDir =>
      widget.store.directory.isEmpty ? '.' : widget.store.directory;

  /// Запись в журнал приложения (окно «Журнал событий» в шапке).
  void _log(String message, {LogLevel level = LogLevel.info}) =>
      AppLog.instance.record('Отчёты', message, level: level);

  /// Облачный путь (web + активная сессия): отчёт генерирует `services/api`
  /// через domain-worker (ADR-2, §12.8), затем скачиваем потоком.
  /// null — вне облачного режима: генерация локально (как раньше).
  Future<Uint8List?> _cloudReport(String fmt, {String? paths}) async {
    final api = widget.store.api;
    final project = widget.project;
    if (api == null || project == null) return null;
    final token = await widget.store.tokenProvider?.call();
    if (token == null || token.isEmpty) return null;
    final cloudId = await widget.store.ensureCloudId(project);
    if (cloudId == null) return null;
    final result = await api.generateReport(
      token,
      cloudId,
      fmt,
      state: project.toJson(),
      layoutParams: layoutParamsToJson(project.params),
      fontBase64: fmt == 'pdf' && _fontBytes != null
          ? base64Encode(_fontBytes!)
          : null,
      paths: paths,
    );
    final download = result['download'];
    if (download is! String || download.isEmpty) {
      throw StateError('Сервис не вернул ссылку на отчёт.');
    }
    final bytes = await api.reportDownload(token, download);
    _log('Отчёт $fmt сгенерирован на сервере (services/api, §12.8).');
    return bytes;
  }

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
      final Uint8List pdf;
      final cloud = await _cloudReport('pdf');
      if (cloud != null) {
        pdf = cloud;
      } else {
        final font = _fontBytes;
        if (font == null) {
          throw StateError('Кириллический шрифт не загружен (assets/fonts/'
              'DejaVuSans.ttf)');
        }
        pdf = await _buildPdfBytes(project, font);
      }
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
      final xlsx =
          await _cloudReport('xlsx') ?? await _buildXlsxBytes(project);
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
      final master = await _cloudReport('dxf', paths: 'master') ??
          Uint8List.fromList(utf8.encode(await _buildMasterDxfText(project)));
      final names = <String>['02_Вылеченный_Мастер.dxf'];
      await saveReport(_outDir, '02_Вылеченный_Мастер.dxf', master);
      if (project.arrayPaths.isNotEmpty) {
        final arr = await _cloudReport('dxf', paths: 'array') ??
            Uint8List.fromList(utf8.encode(await _buildArrayDxfText(project)));
        names.add('03_Раскрой.dxf');
        await saveReport(_outDir, '03_Раскрой.dxf', arr);
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
