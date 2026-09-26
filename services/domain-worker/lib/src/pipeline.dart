/// Доменная цепочка `packages/core` на стороне сервера (ADR-2):
/// `parse → heal/analyze → pattern → calc → variants → teo`.
///
/// Здесь только вызовы канонических функций домена (`packages/core`
/// НЕ изменяется): `parseBytes`, `analyzeManufacturability`, `healGeometry`,
/// `PatternRecognizer().analyze`, `generateArrayGrid`, `multiplyPaths`,
/// `computeMaterialAuto`, `enumerateVariants`, `shapeFromPreset`,
/// `computeConsumption`, `computeTeo`, `compareTeoVariants`.
///
/// Все стадии детерминированы: одинаковый вход → одинаковый выход
/// (эталон PRD §10.2: 26.18 %, 2032.0 мм², costPer1000 = 704.88 ₽).
///
/// Границы ответственности: сеть/объектное хранилище/чтение файлов —
/// на стороне `api` (он присылает байты в `file_base64` или готовую
/// геометрию в `rawPaths`); воркер не ходит сам ни в S3, ни по HTTP, поэтому
/// изолят занят только счётом.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:prepress_core/prepress_core.dart';

import 'errors.dart';
import 'params.dart';
import 'report_stage.dart';
import 'state.dart';

/// Порядок стадий доменной цепочки (System Design §3.1 / ADR-2).
const List<String> kStageOrder = [
  'parse',
  'analyze',
  'heal',
  'pattern',
  'calc',
  'variants',
  'teo',
];

/// Эталонные числа PRD §10.2 (сценарий: 50×30, зазоры 3, Z=96, CP=3.175,
/// cyl=web=300, N=5000, каталог `PriceCatalog.defaults()`).
const Map<String, double> kReference = {
  'wastePct': 26.18,
  'perLabelArea': 2032.0,
  'lengthMm': 34137.6,
  'rapportMm': 304.8,
  'costPer1000': 704.88,
  'totalCost': 3552.58,
  'machineCost': 2528.45,
  'materialCost': 1024.13,
};

/// Допуск сверки эталонных чисел (домен округляет до 2 знаков).
const double kReferenceEps = 0.005;

/// Разбор параметров ТЭО из запроса.
class TeoOptions {
  final PriceCatalog catalog;
  final AssortmentItem material;
  final Machine machine;
  final TeoInput input;

  const TeoOptions({
    required this.catalog,
    required this.material,
    required this.machine,
    required this.input,
  });
}

/// Результат прогона цепочки по одному запросу.
class PipelineResult {
  final ProjectState state;
  final List<String> stages;
  final Map<String, dynamic> stageResults;
  final Map<String, dynamic> metrics;
  final List<String> warnings;

  PipelineResult({
    required this.state,
    required this.stages,
    required this.stageResults,
    required this.metrics,
    required this.warnings,
  });

  /// Полный ответ сервиса (JSON).
  Map<String, dynamic> toJson({bool includeRawPaths = true}) => {
        'schemaVersion': kProjectStateSchemaVersion,
        'stages': stages,
        'stageResults': stageResults,
        'state': state.toProjectStateJson(includeRawPaths: includeRawPaths),
        ...state.toServerSectionsJson(),
        'metrics': metrics,
        if (warnings.isNotEmpty) 'warnings': warnings,
      };
}

/// Приведение синонимов ключей запроса (`state` → `appState`, `teo` →
/// `teoInput`), чтобы клиенты с разными названиями работали одинаково.
Map<String, dynamic> normalizeRequestKeys(Map<String, dynamic> body) {
  final req = Map<String, dynamic>.from(body);
  if (req['appState'] == null && req['state'] is Map) {
    req['appState'] = req['state'];
  }
  if (req['teoInput'] == null && req['teo'] is Map) {
    req['teoInput'] = req['teo'];
  }
  return req;
}

// ============================================================
// Основной прогон
// ============================================================

/// Выполнить доменную цепочку по JSON-запросу воркера.
///
/// Тяжёлые стадии исполняются синхронно: этот код работает внутри изолята
/// (`isolate_executor.dart`), поэтому главный поток сервера не блокируется.
PipelineResult runPipeline(Map<String, dynamic> request) {
  final stopwatch = Stopwatch()..start();
  final warnings = <String>[];

  final requested = _requestedStages(request);
  final needed = _expandStages(requested, request);
  // includeErrors: true — дополнительно вернуть тяжёлые данные внутри
  // stageResults (issues/items/pathsJson/pattern). По умолчанию секции
  // компактны: полные данные и так есть в каноническом `state`.
  final withErrors = request['includeErrors'] == true;

  final stateJson = (request['appState'] as Map?)?.cast<String, dynamic>() ??
      const <String, dynamic>{};
  final state = ProjectState(
    name: (request['name'] as String?) ??
        (stateJson['name'] as String?) ??
        'Проект',
    inputFile: (request['inputFile'] as String?) ??
        (stateJson['inputFile'] as String?) ??
        '',
  );

  // Параметры: значения из appState, поверх — переопределения запроса.
  final stateParams =
      (stateJson['params'] as Map?)?.cast<String, dynamic>() ?? const {};
  final requestParams =
      (request['params'] as Map?)?.cast<String, dynamic>() ?? const {};
  state.params = layoutParamsFromJson({...stateParams, ...requestParams});
  state.manufacturingParams = manufacturingParamsFromJson(
      (request['manufacturingParams'] as Map?)?.cast<String, dynamic>() ??
          const {});

  final stageResults = <String, dynamic>{};
  final timings = <String, int>{};

  void time(String name, void Function() body) {
    final sw = Stopwatch()..start();
    body();
    sw.stop();
    timings[name] = sw.elapsedMilliseconds;
  }

  // ---- parse ----
  if (needed.contains('parse')) {
    time('parse', () {
      stageResults['parse'] =
          parseStage(request, state, stateJson, withErrors);
    });
  }

  // ---- heal + analyze (анализ — по вылеченной геометрии, как в UI) ----
  if (needed.contains('geometry')) {
    time('geometry', () {
      final healed = healGeometry(state.rawPaths, state.manufacturingParams);
      state.healedPaths = healed;
      final report =
          analyzeManufacturability(healed, state.manufacturingParams);
      state.issues = report.issues;
      if (needed.contains('heal')) {
        stageResults['heal'] = {
          'pathsBefore': state.rawPaths.length,
          'paths': healed.length,
          'closed': healed.where((p) => p.isClosed).length,
        };
      }
      if (needed.contains('analyze')) {
        stageResults['analyze'] = {
          'ok': report.ok,
          'verdict': report.verdict,
          'counts': report.counts,
          'issuesCount': report.issues.length,
          if (withErrors)
            'issues': [for (final i in report.issues) issueToJson(i)],
        };
      }
    });
  }

  // ---- pattern ----
  if (needed.contains('pattern')) {
    time('pattern', () {
      stageResults['pattern'] = patternStage(request, state, withErrors);
    });
  }

  // ---- calc ----
  if (needed.contains('calc')) {
    time('calc', () {
      final calc = computeMaterialAuto(state.params);
      state.calc = calc;
      if (calc.error != null) {
        throw WorkerError.geometry(calc.error!, details: {
          'stage': 'calc',
          'params': layoutParamsToJson(state.params),
        });
      }
      stageResults['calc'] = materialResultToJson(calc);
    });
  }

  // ---- variants ----
  if (needed.contains('variants')) {
    time('variants', () {
      final limit = (request['variantsLimit'] as num?)?.toInt() ?? 50;
      final variants = enumerateVariants(state.params, limit: limit);
      state.variants = variants;
      stageResults['variants'] = {
        'count': variants.length,
        'limit': limit,
        if (withErrors)
          'items': [for (final v in variants) materialResultToJson(v, full: false)],
      };
      if (variants.isEmpty) {
        warnings.add('Перебор вариантов не дал ни одного допустимого раскроя — '
            'проверьте ширину цилиндра/полотна, зазоры и раппорт.');
      }
    });
  }

  // ---- teo ----
  if (needed.contains('teo')) {
    time('teo', () {
      stageResults['teo'] = teoStage(request, state);
    });
  }

  // ---- report (§12.8, POST /reports) ----
  // Не стадия цепочки, а надстройка над ней: генерация PDF/XLSX/DXF из
  // состояния после расчёта — внутри того же изолята (ADR-2).
  if (request['report'] is Map) {
    time('report', () {
      stageResults['report'] = reportStage(request, state);
    });
  }

  final stageMs = timings.values.fold<int>(0, (a, b) => a + b);
  stopwatch.stop();

  final metrics = <String, dynamic>{
    'workerVersion': kWorkerVersion,
    'schemaVersion': kProjectStateSchemaVersion,
    'requestedStages': requested,
    'executedStages': kStageOrder.where(needed.contains).toList(),
    'totalMs': stopwatch.elapsedMilliseconds,
    'stagesMs': timings,
    'domainMs': stageMs,
    'counting': _counting(state),
    'reference': referenceCheck(state),
    'rawPaths': state.rawPaths.length,
    'healedPaths': state.healedPaths.length,
    'issues': state.issues.length,
  };

  return PipelineResult(
    state: state,
    stages: requested,
    stageResults: stageResults,
    metrics: metrics,
    warnings: warnings,
  );
}

// ============================================================
// Стадии
// ============================================================

/// Разбор входных байтов в геометрию (`rawPaths`).
///
/// Источник (в порядке приоритета): `file_base64` → `file_path` → готовая
/// геометрия `rawPaths` (в запросе или в `appState.rawPaths`).
Map<String, dynamic> parseStage(
  Map<String, dynamic> request,
  ProjectState state,
  Map<String, dynamic> stateJson,
  bool withErrors,
) {
  final fromRequest = camPathsFromJson(request['rawPaths']);
  final fromState = camPathsFromJson(stateJson['rawPaths']);
  final displayName = _fileDisplayName(request);
  final hasBytes = request['file_base64'] != null || request['file_path'] != null;

  if (!hasBytes && fromRequest.isEmpty && fromState.isEmpty) {
    final storageKey = request['storage_key'] as String?;
    if (storageKey != null && storageKey.isNotEmpty) {
      throw WorkerError.fileUnavailable(
        'Передан только storage_key «$storageKey»: воркер не обращается к '
        'объектному хранилищу напрямую. API должен скачать объект и прислать '
        'байты в file_base64 (либо конвертированный SVG/PDF), а ключ хранить '
        'у себя как метаданные версии файла.',
        details: {'storage_key': storageKey, 'stage': 'parse'},
      );
    }
    throw WorkerError.badRequest(
      'Не передан макет: укажите file_base64, file_path, rawPaths или '
      'appState.rawPaths.',
    );
  }

  if (!hasBytes) {
    state.rawPaths = fromRequest.isNotEmpty ? fromRequest : fromState;
    if (state.inputFile.isEmpty) state.inputFile = displayName;
    return {
      'source': 'rawPaths',
      'paths': state.rawPaths.length,
      if (withErrors) 'pathsJson': camPathsToJson(state.rawPaths),
    };
  }

  final bytes = _readSourceBytes(request);
  final name = _effectiveFileName(displayName, request);
  try {
    final paths = parseBytes(bytes, name);
    state.rawPaths = paths;
    if (state.inputFile.isEmpty) state.inputFile = displayName;
    return {
      'source': request['file_base64'] != null ? 'file_base64' : 'file_path',
      'file': displayName,
      'bytes': bytes.length,
      'paths': paths.length,
      if (withErrors) 'pathsJson': camPathsToJson(paths),
    };
  } on ParserException catch (e) {
    // Русская ошибка домена (F-4). Код `unsupported_format` позволяет API
    // отправить файл в services/converter (ADR-7) и повторить разбор.
    throw WorkerError.unsupportedFormat(e.message,
        details: {'file': displayName, 'stage': 'parse'});
  } on FileSystemException catch (e) {
    throw WorkerError.fileUnavailable(
        'Не удалось прочитать файл «$displayName»: ${e.message}',
        details: {'file': name, 'stage': 'parse'});
  }
}

/// Распознавание массива (Step & Repeat) и автозаполнение параметров раскроя.
Map<String, dynamic> patternStage(
  Map<String, dynamic> request,
  ProjectState state,
  bool withErrors,
) {
  final source =
      state.healedPaths.isNotEmpty ? state.healedPaths : state.rawPaths;
  if (source.isEmpty) {
    throw WorkerError.geometry(
      'Массив не с чем распознавать: геометрия пуста (нужна стадия parse).',
      details: {'stage': 'pattern'},
    );
  }

  final result = PatternRecognizer().analyze(source);
  state.pattern = result;
  state.arrayPaths = const [];

  if (!result.isArray || result.masterPaths.isEmpty) {
    return {
      'isArray': false,
      'pattern': patternResultToJson(result),
      'arrayPaths': 0,
      'message': 'Массив не найден: файл содержит одиночный контур либо '
          'геометрия требует лечения (запросите стадии heal/pattern).',
    };
  }

  // Мастер-элемент: только замкнутые компоненты, отдельный слой (как в UI).
  final layerName = (request['masterLayer'] as String?) ?? 'MASTER';
  final healedAll = healGeometry(result.masterPaths, state.manufacturingParams)
      .map((p) => CamPath(List.of(p.points),
          isClosed: p.isClosed, layerName: layerName))
      .toList();
  final master = [
    for (final p in healedAll)
      if (p.isClosed && p.points.length >= 3) p
  ];
  if (master.isEmpty) {
    throw WorkerError.geometry(
      'Не удалось вылечить мастер-элемент массива: после лечения не осталось '
      'замкнутых контуров (внешний контур + отверстия).',
      details: {'stage': 'pattern', 'recognized': patternResultToJson(result)},
    );
  }

  final cols = result.cols < 1 ? 1 : result.cols;
  final rows = result.rows < 1 ? 1 : result.rows;
  final stepX = result.stepX > 0 ? result.stepX : result.labelW;
  final stepY = result.stepY > 0 ? result.stepY : result.labelH;

  final offsets = _offsetsFromRequest(request);
  final List<CamPath> grid;
  if (offsets != null) {
    grid = multiplyPaths(master, offsets,
        layerName: (request['arrayLayer'] as String?) ?? 'ARRAY');
    state.pattern = PatternResult(
      isArray: true,
      masterPaths: master,
      offsets: offsets,
      rows: rows,
      cols: cols,
      stepX: stepX,
      stepY: stepY,
      gapX: result.gapX,
      gapY: result.gapY,
      count: offsets.length,
      labelW: result.labelW,
      labelH: result.labelH,
      masterArea: result.masterArea,
    );
  } else {
    grid = generateArrayGrid(master,
        cols: cols, rows: rows, stepX: stepX, stepY: stepY);
  }
  state.arrayPaths = grid;

  // Автозаполнение параметров раскроя (как в UI): этикетка — по вылеченному
  // мастеру, зазоры = шаг − этикетка.
  final bounds = pathsBounds(master);
  final labelW = bounds.w > 0 ? bounds.w : result.labelW;
  final labelH = bounds.h > 0 ? bounds.h : result.labelH;
  final gapX = stepX > 0 ? (stepX - labelW).clamp(0.0, stepX).toDouble() : 0.0;
  final gapY = stepY > 0 ? (stepY - labelH).clamp(0.0, stepY).toDouble() : 0.0;
  state.params = state.params.copyWith(
    labelW: labelW,
    labelH: labelH,
    gapX: gapX,
    gapY: gapY,
  );

  return {
    'isArray': true,
    'grid': {
      'rows': rows,
      'cols': cols,
      'stepX': stepX,
      'stepY': stepY,
      'masterPaths': master.length,
      'arrayPaths': grid.length,
      'offsets': offsets == null ? rows * cols : offsets.length,
    },
    'params': layoutParamsToJson(state.params),
    'pattern': withErrors ? patternResultToJson(state.pattern!) : null,
  };
}

/// ТЭО: раскрой выбранного варианта + расход по форме + сравнение вариантов.
Map<String, dynamic> teoStage(
  Map<String, dynamic> request,
  ProjectState state,
) {
  final calc = state.calc ?? computeMaterialAuto(state.params);
  state.calc = calc;
  if (calc.error != null) {
    throw WorkerError.geometry(calc.error!, details: {'stage': 'teo'});
  }

  final opts = teoOptions(request);
  // Форма этикетки — как в UI: прямоугольник по габаритам раскроя
  // (`shapeFromPreset('rect', …)`), поэтому расход совпадает с эталоном.
  final shape = shapeFromPreset('rect', calc.labelW, calc.labelH);
  final cons = computeConsumption(calc, shape);
  final teo = computeTeo(calc, cons, opts.input);
  if (teo.error != null) {
    throw WorkerError.geometry(teo.error!, details: {'stage': 'teo'});
  }
  state.shape = shape;
  state.consumption = cons;
  state.teo = teo;
  state.teoInput = teoInputToJson(opts.material, opts.machine,
      opts.catalog.workTime, opts.input, opts.catalog.currency);
  state.priceCatalog = opts.catalog.toJson();

  // Сравнение вариантов: топ-N по себестоимости (как перебор в UI).
  // Если стадия variants выполнялась — берём её список, иначе считаем свой
  // ограниченный перебор, чтобы ТЭО не тянуло за собой полный перебор.
  final comparisonLimit = (request['teoComparisonLimit'] as num?)?.toInt() ?? 10;
  var variants = state.variants;
  if (variants.isEmpty) {
    variants = enumerateVariants(state.params,
        limit: comparisonLimit > 0 ? comparisonLimit : 0);
    state.variants = variants;
  }
  final cmp = compareTeoVariants(
    variants,
    (v) => computeConsumption(v, shapeFromPreset('rect', v.labelW, v.labelH)),
    opts.input,
  );
  state.comparison = cmp;

  final best = cmp.variants.isEmpty ? null : cmp.variants.first;
  return {
    'calc': materialResultToJson(calc),
    'consumption': consumptionToJson(cons),
    'shape': shapeToJson(shape),
    'teo': teoResultToJson(teo),
    'teoInput': state.teoInput,
    'comparison': comparisonToJson(cmp),
    'best': best == null
        ? null
        : {
            'costPer1000': best.$2.costPer1000,
            'rotated': best.$1.rotated,
            'rows': best.$1.rows,
            'cols': best.$1.cols,
          },
  };
}

// ============================================================
// Разбор запроса
// ============================================================

/// Запрошенные стадии (по умолчанию — вся цепочка).
List<String> _requestedStages(Map<String, dynamic> request) {
  final raw = request['stages'];
  final requested = <String>[];
  void add(String s) {
    if (s == 'all' || s == 'full') {
      requested
        ..clear()
        ..addAll(kStageOrder);
      return;
    }
    if (s == 'calculate' || s == 'calculation') {
      for (final stage in kStageOrder) {
        if (!requested.contains(stage)) requested.add(stage);
      }
      return;
    }
    if (!kStageOrder.contains(s)) {
      throw WorkerError.badRequest(
          'Неизвестная стадия «$s». Доступные: ${kStageOrder.join(', ')}.');
    }
    if (!requested.contains(s)) requested.add(s);
  }

  if (raw is List) {
    for (final e in raw) {
      add(e.toString().trim().toLowerCase());
    }
  } else if (raw is String) {
    add(raw.trim().toLowerCase());
  } else {
    return List.of(kStageOrder);
  }
  if (requested.isEmpty) return List.of(kStageOrder);
  requested
      .sort((a, b) => kStageOrder.indexOf(a).compareTo(kStageOrder.indexOf(b)));
  return requested;
}

/// Развернуть запрошенные стадии в выполняемый набор (с зависимостями).
///
/// Раскрой/перебор/ТЭО считаются и без геометрии (эталонный сценарий PRD
/// §10.2 задаётся только параметрами), поэтому `parse` добавляется к таким
/// запросам лишь тогда, когда входная геометрия действительно передана.
Set<String> _expandStages(List<String> requested, Map<String, dynamic> request) {
  final need = <String>{};

  final geometryRequested = requested.contains('parse') ||
      requested.contains('heal') ||
      requested.contains('analyze') ||
      requested.contains('pattern');
  if (geometryRequested) {
    need.addAll(['parse', 'geometry']);
  } else if (_hasGeometryInput(request)) {
    // Модель считает, но макет передан — разберём его, чтобы отдать
    // `state.rawPaths` (в том числе для includeRawPaths) и сверить геометрию.
    need.addAll(['parse', 'geometry']);
  }
  if (requested.contains('heal')) need.add('heal');
  if (requested.contains('analyze')) need.add('analyze');
  if (requested.contains('pattern')) need.add('pattern');
  if (requested.contains('calc')) need.addAll(['calc']);
  if (requested.contains('variants')) need.addAll(['calc', 'variants']);
  if (requested.contains('teo')) need.addAll(['calc', 'teo']);
  return need;
}

/// Передан ли макет (байты/путь) либо готовая геометрия.
bool _hasGeometryInput(Map<String, dynamic> request) {
  if (request['file_base64'] != null || request['file_path'] != null) {
    return true;
  }
  if (request['storage_key'] != null) return true;
  final direct = request['rawPaths'];
  if (direct is List && direct.isNotEmpty) return true;
  final appState = request['appState'];
  if (appState is Map) {
    final paths = appState['rawPaths'];
    if (paths is List && paths.isNotEmpty) return true;
  }
  return false;
}

String _effectiveFileName(String displayName, Map<String, dynamic> request) {
  final named = request['fileName'] as String?;
  final candidates = [
    if (named != null && named.isNotEmpty) named,
    if (displayName.isNotEmpty) displayName,
    (request['file_path'] as String?) ?? '',
  ];
  for (final c in candidates) {
    if (c.contains('.')) return c;
  }
  throw WorkerError.badRequest(
    'Не удалось определить формат файла (ожидается расширение dxf/svg/pdf/ai): '
    'передайте fileName вместе с байтами.',
  );
}

String _fileDisplayName(Map<String, dynamic> request) {
  final name = request['fileName'] as String?;
  if (name != null && name.isNotEmpty) return name;
  final path = request['file_path'] as String?;
  if (path != null && path.isNotEmpty) {
    return path.split(RegExp(r'[/\\]')).last;
  }
  return '';
}

/// Байты макета: `file_base64` (в приоритете) или локальный `file_path`.
Uint8List _readSourceBytes(Map<String, dynamic> request) {
  final b64 = request['file_base64'] as String?;
  if (b64 != null) {
    final clean = b64.trim().replaceAll(RegExp(r'\s'), '');
    if (clean.isEmpty) {
      throw WorkerError.badRequest('file_base64 пуст.');
    }
    try {
      return base64Decode(clean);
    } catch (e) {
      throw WorkerError.badRequest(
          'Не удалось декодировать file_base64 (ожидается чистый base64 без '
          'data-URL-префикса): $e');
    }
  }

  final path = request['file_path'] as String?;
  if (path != null && path.isNotEmpty) {
    final f = File(path);
    if (!f.existsSync()) {
      throw WorkerError.fileUnavailable(
          'Файл не найден: $path (в контейнере доступны только смонтированные '
          'каталоги, например PP_DATA_DIR).',
          details: {'file_path': path});
    }
    return f.readAsBytesSync();
  }

  throw WorkerError.badRequest('Не передан источник байтов макета.');
}

/// Смещения массива из запроса (пары `[x, y]`); при наличии заменяют сетку
/// `generateArrayGrid` (используется, когда закон массива пришёл из UI).
List<Vec2>? _offsetsFromRequest(Map<String, dynamic> request) {
  final raw = request['patternOffsets'];
  if (raw is! List || raw.isEmpty) return null;
  final out = <Vec2>[];
  for (final e in raw) {
    if (e is List && e.length >= 2) {
      out.add(Vec2((e[0] as num).toDouble(), (e[1] as num).toDouble()));
    }
  }
  return out.isEmpty ? null : out;
}

/// Сводка ТЭО: каталог цен, сортамент, машина и ставки.
TeoOptions teoOptions(Map<String, dynamic> request) {
  final catalog = priceCatalogFromJson(
      (request['priceCatalog'] as Map?)?.cast<String, dynamic>());
  if (catalog.assortment.isEmpty || catalog.machines.isEmpty) {
    throw WorkerError.badRequest(
        'Каталог цен неполон: нужны хотя бы один материал сортамента и одна '
        'машина со скоростью (м/мин) или производительностью (шт/ч).');
  }
  final teoIn = (request['teoInput'] as Map?)?.cast<String, dynamic>() ?? const {};

  AssortmentItem material = catalog.assortment.first;
  final materialId = teoIn['materialId'] as String?;
  if (materialId != null && materialId.isNotEmpty) {
    final found = catalog.assortment.where((a) => a.id == materialId).toList();
    if (found.isEmpty) {
      throw WorkerError.badRequest(
          'Материал «$materialId» не найден в каталоге. Доступные: '
          '${catalog.assortment.map((a) => a.id).join(', ')}.');
    }
    material = found.first;
  }

  Machine machine = catalog.machines.first;
  final machineId = teoIn['machineId'] as String?;
  if (machineId != null && machineId.isNotEmpty) {
    final found = catalog.machines.where((m) => m.id == machineId).toList();
    if (found.isEmpty) {
      throw WorkerError.badRequest(
          'Машина «$machineId» не найдена в каталоге. Доступные: '
          '${catalog.machines.map((m) => m.id).join(', ')}.');
    }
    machine = found.first;
  }

  final workTime = WorkTime(
    hoursPerShift: (teoIn['hoursPerShift'] as num?)?.toDouble() ??
        catalog.workTime.hoursPerShift,
    shiftsPerDay: (teoIn['shiftsPerDay'] as num?)?.toInt() ??
        catalog.workTime.shiftsPerDay,
  );

  final input = TeoInput(
    material: material,
    machine: machine,
    workTime: workTime,
    toolingCost: (teoIn['toolingCost'] as num?)?.toDouble() ?? 0,
    markupPct: (teoIn['markupPct'] as num?)?.toDouble() ?? 0,
    setupMaterialMeters: (teoIn['setupMaterialMeters'] as num?)?.toDouble(),
    shiftCostPerShift: (teoIn['shiftCostPerShift'] as num?)?.toDouble() ?? 0,
  );
  return TeoOptions(
      catalog: catalog, material: material, machine: machine, input: input);
}

// ============================================================
// Сводки и утилиты
// ============================================================

Map<String, dynamic> _counting(ProjectState state) {
  final calc = state.calc;
  return {
    'rows': calc?.rows ?? 0,
    'cols': calc?.cols ?? 0,
    'perRev': calc?.perRev ?? 0,
    'revs': calc?.revs ?? 0,
    'count': calc?.count ?? 0,
    'countRequested': calc?.countRequested ?? 0,
    'excessLabels': calc?.excessLabels ?? 0,
    'lengthMm': calc?.length ?? 0,
    'rapportMm': calc?.rapport ?? 0,
    'wastePct': calc?.wastePct ?? 0,
    'perLabelAreaMm2': calc?.perLabelArea ?? 0,
    'variants': state.variants.length,
  };
}

/// Сверка эталонных чисел PRD §10.2. `checked=false` — сценарий не эталонный
/// (другие параметры), сравнение не имеет смысла.
Map<String, dynamic> referenceCheck(ProjectState state) {
  final calc = state.calc;
  final teo = state.teo;
  final p = state.params;
  final isReference = p.labelW == 50 &&
      p.labelH == 30 &&
      p.gapX == 3 &&
      p.gapY == 3 &&
      p.zTeeth == 96 &&
      p.cp == 3.175 &&
      p.rapportManual == 0 &&
      p.cylWidth == 300 &&
      p.webWidth == 300 &&
      p.undercut == 0.48 &&
      p.minGap == 3 &&
      p.mode == 'count' &&
      p.count == 5000;
  if (!isReference || calc == null) {
    return {'checked': false, 'passed': null};
  }
  final actual = <String, double>{
    'wastePct': calc.wastePct,
    'perLabelArea': calc.perLabelArea,
    'lengthMm': calc.length,
    'rapportMm': calc.rapport,
    if (teo != null) ...{
      'costPer1000': teo.costPer1000,
      'totalCost': teo.totalCost,
      'machineCost': teo.machineCost,
      'materialCost': teo.materialCost,
    },
  };
  final expected = <String, double>{
    for (final e in kReference.entries)
      if (actual.containsKey(e.key)) e.key: e.value
  };
  var passed = true;
  final deltas = <String, double>{};
  expected.forEach((k, v) {
    final d = (actual[k] ?? double.nan) - v;
    deltas[k] = d;
    if (!(d.abs() <= kReferenceEps)) passed = false;
  });
  return {
    'checked': true,
    'passed': passed,
    'expected': expected,
    'actual': actual,
    'delta': deltas,
    'eps': kReferenceEps,
  };
}

/// Габариты набора путей (bbox по всем точкам).
({double w, double h}) pathsBounds(List<CamPath> paths) {
  var minX = double.infinity, minY = double.infinity;
  var maxX = double.negativeInfinity, maxY = double.negativeInfinity;
  for (final p in paths) {
    for (final v in p.points) {
      if (v.x < minX) minX = v.x;
      if (v.y < minY) minY = v.y;
      if (v.x > maxX) maxX = v.x;
      if (v.y > maxY) maxY = v.y;
    }
  }
  if (minX == double.infinity) return (w: 0.0, h: 0.0);
  return (w: maxX - minX, h: maxY - minY);
}
