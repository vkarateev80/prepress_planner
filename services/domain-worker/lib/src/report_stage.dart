/// Стадия отчётов (§12.8): PDF ТЭО / XLSX / DXF на сервере.
///
/// Те же чистые функции `packages/core`, что и в UI (`buildTeoReportPdf`,
/// `buildTeoXlsx`, `buildDxfText`), но исполняются в изоляте воркера (ADR-2):
/// браузер отчёты не строит. Вход — результат цепочки `calculate` (state
/// с `calc`/`teo`/`healedPaths`/`arrayPaths`) плюс секция запроса:
///
///     "report": {"format": "pdf" | "xlsx" | "dxf",
///                "paths": "master" | "array",   // только для dxf
///                "fontBase64": "…" }            // TTF для PDF (кириллица)
///
/// Шрифт для PDF: `fontBase64` → env `PP_FONT_PATH` → файл из комплекта
/// (`app/assets/fonts/DejaVuSans.ttf` относительно корня репозитория) →
/// системный поиск `fontPathForCyrillic()`. Без шрифта — ошибка с русским
/// сообщением (кириллица в PDF иначе невозможна).
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:prepress_core/io.dart';
import 'package:prepress_core/prepress_core.dart';

import 'errors.dart';
import 'pipeline.dart';
import 'state.dart';

/// Собрать отчёт по состоянию проекта. Ключ `report` в запросе обязателен.
Map<String, dynamic> reportStage(
    Map<String, dynamic> request, ProjectState state) {
  final report = (request['report'] as Map).cast<String, dynamic>();
  final format = (report['format'] as String? ?? '').trim().toLowerCase();

  switch (format) {
    case 'pdf':
      final data = _reportData(request, state);
      final bytes = buildTeoReportPdf(data, _fontBytes(report));
      return _payload('pdf', '${_baseName(state)}_ТЭО.pdf',
          'application/pdf', bytes);
    case 'xlsx':
      final data = _reportData(request, state);
      final bytes = buildTeoXlsx(data);
      return _payload(
          'xlsx',
          '${_baseName(state)}_ТЭО.xlsx',
          'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
          bytes);
    case 'dxf':
      return _dxf(report, state);
    default:
      throw WorkerError.badRequest(
          'Формат отчёта: pdf, xlsx или dxf. Получен: '
          '«${format.isEmpty ? 'не указан' : format}».',
          details: {'stage': 'report'});
  }
}

/// Данные отчёта из состояния (как `_buildReportData` в UI, но по
/// серверному state: переиспользуем результаты стадий calc/teo, при их
/// отсутствии считаем по тем же функциям домена).
TeoReportData _reportData(Map<String, dynamic> request, ProjectState state) {
  final calc = state.calc;
  if (calc == null || calc.error != null) {
    throw WorkerError.geometry(
        'Расчёт раскроя не выполнен — для отчёта нужна стадия calc '
        '(state.calc отсутствует).',
        details: {'stage': 'report'});
  }
  final shape =
      state.shape ?? shapeFromPreset('rect', calc.labelW, calc.labelH);
  final cons = state.consumption ?? computeConsumption(calc, shape);
  final opts = teoOptions(request);
  final teo = state.teo ?? computeTeo(calc, cons, opts.input);
  if (teo.error != null) {
    throw WorkerError.geometry(teo.error!, details: {'stage': 'report'});
  }
  final comparison = state.comparison ??
      compareTeoVariants(
          state.variants.isNotEmpty ? state.variants : [calc],
          (v) => computeConsumption(
              v, shapeFromPreset('rect', v.labelW, v.labelH)),
          opts.input);
  return TeoReportData(
    projectName: state.name.isEmpty ? 'Проект' : state.name,
    inputFile: state.inputFile,
    params: state.params,
    shape: shape,
    calc: calc,
    consumption: cons,
    teo: teo,
    comparison: comparison,
    material: opts.material,
    machine: opts.machine,
    workTime: opts.catalog.workTime,
    currency: opts.catalog.currency,
    date: DateTime.now(),
  );
}

/// DXF: мастер (`healedPaths`) либо массив (`arrayPaths`).
Map<String, dynamic> _dxf(Map<String, dynamic> report, ProjectState state) {
  final target = (report['paths'] as String? ?? 'master').trim().toLowerCase();
  final List<CamPath> paths;
  if (target == 'master') {
    paths = state.healedPaths;
  } else if (target == 'array') {
    paths = state.arrayPaths;
  } else {
    throw WorkerError.badRequest(
        'report.paths: master или array. Получен: «$target».',
        details: {'stage': 'report'});
  }
  if (paths.isEmpty) {
    throw WorkerError.geometry(
        target == 'array'
            ? 'Массив не распознан — экспортировать нечего (state.arrayPaths пуст).'
            : 'Нет геометрии: файл не импортирован или лечение не выполнялось '
                '(state.healedPaths пуст).',
        details: {'stage': 'report'});
  }
  final suffix = target == 'array' ? '-массив' : '-мастер';
  final bytes = utf8.encode(buildDxfText(paths));
  return _payload('dxf', '${_baseName(state)}$suffix.dxf', 'application/dxf',
      Uint8List.fromList(bytes));
}

String _baseName(ProjectState state) {
  final name = state.name.trim().isEmpty ? 'Проект' : state.name.trim();
  return name.replaceAll(RegExp(r'[^\w\-\u0400-\u04FF ]'), '_');
}

Map<String, dynamic> _payload(
    String format, String name, String mime, Uint8List bytes) {
  return {
    'format': format,
    'name': name,
    'mime': mime,
    'size': bytes.length,
    'contentBase64': base64Encode(bytes),
  };
}

/// Шрифт TTF для кириллицы в PDF (см. шапку файла).
Uint8List _fontBytes(Map<String, dynamic> report) {
  final b64 = report['fontBase64'];
  if (b64 is String && b64.isNotEmpty) {
    try {
      final bytes = base64Decode(b64);
      if (bytes.isEmpty) throw FormatException('пусто');
      return bytes;
    } on FormatException {
      throw WorkerError.badRequest(
          'report.fontBase64 содержит некорректный base64.',
          details: {'stage': 'report'});
    }
  }
  final candidates = <String>[
    Platform.environment['PP_FONT_PATH'] ?? '',
    ..._repoFontPaths(),
    fontPathForCyrillic() ?? '',
  ];
  for (final path in candidates) {
    if (path.isEmpty) continue;
    final file = File(path);
    if (file.existsSync()) {
      final bytes = file.readAsBytesSync();
      if (bytes.isNotEmpty) return bytes;
    }
  }
  throw WorkerError.badRequest(
      'Шрифт для кириллицы не найден: передайте report.fontBase64 '
      '(DejaVuSans.ttf) либо задайте PP_FONT_PATH на сервере.',
      details: {'stage': 'report'});
}

/// Комплектный шрифт приложения `app/assets/fonts/DejaVuSans.ttf`:
/// относительно скрипта (`bin/domain_worker.dart` → корень репозитория) и
/// относительно рабочего каталога (запуск из `services/domain-worker`).
List<String> _repoFontPaths() {
  final script = Platform.script.toFilePath();
  final binDir = Directory(script).parent;
  final root = binDir.parent.parent.parent.path;
  return [
    '$root/app/assets/fonts/DejaVuSans.ttf',
    '${Directory.current.path}/../../app/assets/fonts/DejaVuSans.ttf',
  ];
}
