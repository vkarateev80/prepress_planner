/// Модель проекта «Препресс-Планер» + сериализация project_state.json v2.
library;

import 'dart:convert';

import 'package:prepress_core/prepress_core.dart';

import '../../platform/json_store.dart';
import 'cloud_projects.dart';

/// Сериализация CamPath: {points: [[x,y],...], closed, layer}.
Map<String, dynamic> camPathToJson(CamPath p) => {
      'points': [
        for (final v in p.points) [v.x, v.y]
      ],
      'closed': p.isClosed,
      'layer': p.layerName,
    };

CamPath camPathFromJson(Map<String, dynamic> j) {
  final pts = <Vec2>[];
  for (final e in (j['points'] as List? ?? const [])) {
    final a = e as List;
    pts.add(Vec2((a[0] as num).toDouble(), (a[1] as num).toDouble()));
  }
  return CamPath(pts,
      isClosed: j['closed'] == true,
      layerName: (j['layer'] as String?) ?? '');
}

/// Параметры раскроя → JSON.
Map<String, dynamic> layoutParamsToJson(LayoutParams p) => {
      'labelW': p.labelW,
      'labelH': p.labelH,
      'gapX': p.gapX,
      'gapY': p.gapY,
      'zTeeth': p.zTeeth,
      'cp': p.cp,
      'rapportManual': p.rapportManual,
      'cylWidth': p.cylWidth,
      'webWidth': p.webWidth,
      'undercut': p.undercut,
      'minGap': p.minGap,
      'mode': p.mode,
      'count': p.count,
      'length': p.length,
    };

LayoutParams layoutParamsFromJson(Map<String, dynamic> j) => LayoutParams(
      labelW: (j['labelW'] as num?)?.toDouble() ?? 50,
      labelH: (j['labelH'] as num?)?.toDouble() ?? 30,
      gapX: (j['gapX'] as num?)?.toDouble() ?? 3,
      gapY: (j['gapY'] as num?)?.toDouble() ?? 3,
      zTeeth: (j['zTeeth'] as num?)?.toInt() ?? 96,
      cp: (j['cp'] as num?)?.toDouble() ?? 3.175,
      rapportManual: (j['rapportManual'] as num?)?.toDouble() ?? 0,
      cylWidth: (j['cylWidth'] as num?)?.toDouble() ?? 300,
      webWidth: (j['webWidth'] as num?)?.toDouble() ?? 300,
      undercut: (j['undercut'] as num?)?.toDouble() ?? 0.48,
      minGap: (j['minGap'] as num?)?.toDouble() ?? 3,
      mode: (j['mode'] as String?) ?? 'count',
      count: (j['count'] as num?)?.toInt() ?? 5000,
      length: (j['length'] as num?)?.toDouble() ?? 10000,
    );

/// Состояние проекта (все вычисляемые данные UI).
class Project {
  String name;
  String inputFile;

  /// Идентификатор исходника в `services/api` (файлы облака, §12.5):
  /// заполняется после облачной загрузки (`flutter-web-adapt`), используется
  /// для скачивания blob через `GET /api/files/{id}/download`. null — файла
  /// в облаке нет (desktop / анонимный режим).
  String? inputFileId;

  LayoutParams params;
  List<CamPath> rawPaths;
  List<CamPath> healedPaths;
  List<Issue> issues;
  PatternResult? pattern;
  List<CamPath> arrayPaths;
  MaterialResult? calc;
  List<MaterialResult> variants;
  int selectedVariantIndex;
  DateTime updatedAt;

  Project({
    required this.name,
    String? inputFile,
    this.inputFileId,
    LayoutParams? params,
    List<CamPath>? rawPaths,
    List<CamPath>? healedPaths,
    List<Issue>? issues,
    this.pattern,
    List<CamPath>? arrayPaths,
    this.calc,
    List<MaterialResult>? variants,
    this.selectedVariantIndex = 0,
    DateTime? updatedAt,
  })  : inputFile = inputFile ?? '',
        params = params ?? LayoutParams(),
        rawPaths = rawPaths ?? [],
        healedPaths = healedPaths ?? [],
        issues = issues ?? [],
        arrayPaths = arrayPaths ?? [],
        variants = variants ?? [],
        updatedAt = updatedAt ?? DateTime.now();

  Map<String, dynamic> toJson() => {
        'schemaVersion': 2,
        'name': name,
        'inputFile': inputFile,
        'params': layoutParamsToJson(params),
        'rawPaths': [for (final p in rawPaths) camPathToJson(p)],
        'healedPaths': [for (final p in healedPaths) camPathToJson(p)],
        'issues': [for (final i in issues) issueToJson(i)],
        'pattern': pattern == null ? null : patternResultToJson(pattern!),
        'arrayPaths': [for (final p in arrayPaths) camPathToJson(p)],
        'calc': calc == null ? null : materialResultToJson(calc!),
        'variants': [for (final v in variants) materialResultToJson(v)],
        'selectedVariantIndex': selectedVariantIndex,
        if (inputFileId != null) 'inputFileId': inputFileId,
        'updatedAt': updatedAt.toIso8601String(),
      };

  factory Project.fromJson(Map<String, dynamic> j) {
    final calcJson = j['calc'];
    final variants = [
      for (final e in (j['variants'] as List? ?? const []))
        materialResultFromJson((e as Map).cast<String, dynamic>())
    ];
    final calc = calcJson is Map
        ? materialResultFromJson(calcJson.cast<String, dynamic>())
        : null;
    return Project(
      name: (j['name'] as String?) ?? 'Проект',
      inputFile: (j['inputFile'] as String?) ?? '',
      params: layoutParamsFromJson(
          (j['params'] as Map?)?.cast<String, dynamic>() ?? const {}),
      rawPaths: [
        for (final e in (j['rawPaths'] as List? ?? const []))
          camPathFromJson((e as Map).cast<String, dynamic>())
      ],
      healedPaths: [
        for (final e in (j['healedPaths'] as List? ?? const []))
          camPathFromJson((e as Map).cast<String, dynamic>())
      ],
      issues: [
        for (final e in (j['issues'] as List? ?? const []))
          issueFromJson((e as Map).cast<String, dynamic>())
      ],
      pattern: patternResultFromJson(
          (j['pattern'] as Map?)?.cast<String, dynamic>()),
      arrayPaths: [
        for (final e in (j['arrayPaths'] as List? ?? const []))
          camPathFromJson((e as Map).cast<String, dynamic>())
      ],
      calc: calc,
      variants: variants,
      selectedVariantIndex: (j['selectedVariantIndex'] as num?)?.toInt() ?? 0,
      inputFileId: j['inputFileId'] as String?,
      updatedAt: DateTime.tryParse((j['updatedAt'] as String?) ?? '') ??
          DateTime.now(),
    );
  }
}

Map<String, dynamic> issueToJson(Issue i) => {
      'kind': i.kind,
      'severity': i.severity,
      'points': [
        for (final v in i.points) [v.x, v.y]
      ],
      'message': i.message,
      'suggestion': i.suggestion,
      'fixable': i.fixable,
      'index': i.index,
    };

Issue issueFromJson(Map<String, dynamic> j) => Issue(
      kind: (j['kind'] as String?) ?? '',
      severity: (j['severity'] as String?) ?? 'warning',
      points: [
        for (final e in (j['points'] as List? ?? const []))
          Vec2(((e as List)[0] as num).toDouble(),
              ((e)[1] as num).toDouble())
      ],
      message: (j['message'] as String?) ?? '',
      suggestion: (j['suggestion'] as String?) ?? '',
      fixable: j['fixable'] == true,
      index: (j['index'] as num?)?.toInt() ?? 0,
    );

Map<String, dynamic> patternResultToJson(PatternResult p) => {
      'isArray': p.isArray,
      // Мастер-элемент и закон расположения сохраняются полностью, чтобы
      // после перезапуска можно было перегенерировать массив без повторного
      // распознавания.
      'masterPaths': [for (final q in p.masterPaths) camPathToJson(q)],
      'offsets': [for (final o in p.offsets) [o.x, o.y]],
      'rows': p.rows,
      'cols': p.cols,
      'stepX': p.stepX,
      'stepY': p.stepY,
      'gapX': p.gapX,
      'gapY': p.gapY,
      'count': p.count,
      'labelW': p.labelW,
      'labelH': p.labelH,
      'masterArea': p.masterArea,
    };

PatternResult? patternResultFromJson(Map<String, dynamic>? j) {
  if (j == null) return null;
  return PatternResult(
    isArray: j['isArray'] == true,
    masterPaths: [
      for (final e in (j['masterPaths'] as List? ?? const []))
        camPathFromJson((e as Map).cast<String, dynamic>())
    ],
    offsets: [
      for (final e in (j['offsets'] as List? ?? const []))
        Vec2(((e as List)[0] as num).toDouble(),
            ((e)[1] as num).toDouble())
    ],
    rows: (j['rows'] as num?)?.toInt() ?? 0,
    cols: (j['cols'] as num?)?.toInt() ?? 0,
    stepX: (j['stepX'] as num?)?.toDouble() ?? 0,
    stepY: (j['stepY'] as num?)?.toDouble() ?? 0,
    gapX: (j['gapX'] as num?)?.toDouble() ?? 0,
    gapY: (j['gapY'] as num?)?.toDouble() ?? 0,
    count: (j['count'] as num?)?.toInt() ?? 0,
    labelW: (j['labelW'] as num?)?.toDouble() ?? 0,
    labelH: (j['labelH'] as num?)?.toDouble() ?? 0,
    masterArea: (j['masterArea'] as num?)?.toDouble() ?? 0,
  );
}

Map<String, dynamic> materialResultToJson(MaterialResult r) => {
      'error': r.error,
      'labelW': r.labelW,
      'labelH': r.labelH,
      'rotated': r.rotated,
      'rows': r.rows,
      'cols': r.cols,
      'stepX': r.stepX,
      'stepY': r.stepY,
      'gapYActual': r.gapYActual,
      'usedWidth': r.usedWidth,
      'webMin': r.webMin,
      'perRev': r.perRev,
      'revs': r.revs,
      'count': r.count,
      'excessLabels': r.excessLabels,
      'rapport': r.rapport,
      'dPitch': r.dPitch,
      'dCyl': r.dCyl,
      'length': r.length,
      'webWidth': r.webWidth,
      'areaMm2': r.areaMm2,
      'areaM2': r.areaM2,
      'usedAreaMm2': r.usedAreaMm2,
      'wastePct': r.wastePct,
      'perLabelArea': r.perLabelArea,
      'mode': r.mode,
    };

MaterialResult materialResultFromJson(Map<String, dynamic> j) {
  final error = j['error'] as String?;
  if (error != null) return MaterialResult.withError(error);
  return MaterialResult(
    labelW: (j['labelW'] as num?)?.toDouble() ?? 0,
    labelH: (j['labelH'] as num?)?.toDouble() ?? 0,
    rotated: j['rotated'] == true,
    rows: (j['rows'] as num?)?.toInt() ?? 0,
    cols: (j['cols'] as num?)?.toInt() ?? 0,
    stepX: (j['stepX'] as num?)?.toDouble() ?? 0,
    stepY: (j['stepY'] as num?)?.toDouble() ?? 0,
    gapYActual: (j['gapYActual'] as num?)?.toDouble() ?? 0,
    usedWidth: (j['usedWidth'] as num?)?.toDouble() ?? 0,
    webMin: (j['webMin'] as num?)?.toDouble() ?? 0,
    perRev: (j['perRev'] as num?)?.toInt() ?? 0,
    revs: (j['revs'] as num?)?.toInt() ?? 0,
    count: (j['count'] as num?)?.toInt() ?? 0,
    excessLabels: (j['excessLabels'] as num?)?.toInt() ?? 0,
    rapport: (j['rapport'] as num?)?.toDouble() ?? 0,
    dPitch: (j['dPitch'] as num?)?.toDouble() ?? 0,
    dCyl: (j['dCyl'] as num?)?.toDouble() ?? 0,
    length: (j['length'] as num?)?.toDouble() ?? 0,
    webWidth: (j['webWidth'] as num?)?.toDouble() ?? 0,
    areaMm2: (j['areaMm2'] as num?)?.toDouble() ?? 0,
    areaM2: (j['areaM2'] as num?)?.toDouble() ?? 0,
    usedAreaMm2: (j['usedAreaMm2'] as num?)?.toDouble() ?? 0,
    wastePct: (j['wastePct'] as num?)?.toDouble() ?? 0,
    perLabelArea: (j['perLabelArea'] as num?)?.toDouble() ?? 0,
    mode: (j['mode'] as String?) ?? 'count',
  );
}

/// Хранилище проектов.
///
/// Два режима (задача `flutter-web-adapt`):
/// * **облачный** — если подключён [api] (web, ADR-6) и есть сессия аккаунта
///   ([tokenProvider] вернул токен): CRUD через `/api/projects` (§12.4);
/// * **локальный** — иначе: JSON-файлы (desktop) / localStorage (web).
class ProjectStore {
  /// Имя каталога/префикса хранилища (для UI и сообщений).
  final String directory;
  final JsonStore _store;
  final ProjectsApi? api;
  final Future<String?> Function()? tokenProvider;

  ProjectStore(
    String directory, {
    this.api,
    this.tokenProvider,
  })  : directory = directory,
        _store = JsonStore(directory);

  static String _sanitize(String s) =>
      s.replaceAll(RegExp(r'[^\w\-\u0400-\u04FF ]'), '_').trim();

  String _relFor(String name) => '${_sanitize(name)}.json';

  /// Токен облачного режима: null → локальное хранилище.
  Future<String?> _cloudToken() async {
    if (api == null) return null;
    final t = await tokenProvider?.call();
    return (t == null || t.isEmpty) ? null : t;
  }

  static Map<String, dynamic>? _findByName(
      List<Map<String, dynamic>> items, String name) {
    for (final e in items) {
      if (e['name'] == name) return e;
    }
    return null;
  }

  Future<void> save(Project p) async {
    final token = await _cloudToken();
    if (token != null) {
      final state = p.toJson();
      final items = await api!.list(token);
      final existing = _findByName(items, p.name);
      if (existing != null) {
        await api!.patch(token, existing['id'] as String, state: state);
      } else {
        await api!.create(token, p.name, state);
      }
      return;
    }
    await _store.write(_relFor(p.name), jsonEncode(p.toJson()));
  }

  Future<Project?> load(String name) async {
    final token = await _cloudToken();
    if (token != null) {
      final items = await api!.list(token);
      final found = _findByName(items, name);
      if (found == null) return null;
      final proj = await api!.get(token, found['id'] as String);
      final state = proj['state'];
      if (state is! Map) return null;
      return Project.fromJson(state.cast<String, dynamic>());
    }
    final s = await _store.read(_relFor(name));
    if (s == null) return null;
    final j = jsonDecode(s);
    return Project.fromJson((j as Map).cast<String, dynamic>());
  }

  Future<List<String>> listNames() async {
    final token = await _cloudToken();
    if (token != null) {
      final items = await api!.list(token);
      return [for (final e in items) e['name'] as String? ?? ''];
    }
    return _store.listJsonNames();
  }

  /// Занято ли имя: в облаке — по списку организации, локально — по файлу
  /// (имя санитайзится так же, как при сохранении — два разных имени,
  /// дающих один файл, тоже считаются занятыми).
  Future<bool> exists(String name) async {
    final token = await _cloudToken();
    if (token != null) {
      final items = await api!.list(token);
      return _findByName(items, name) != null;
    }
    return await _store.read(_relFor(name)) != null;
  }

  /// Идентификатор проекта в облаке (создаёт при отсутствии) — нужен для
  /// загрузки файлов (`POST /api/projects/{id}/files`, ADR-7).
  /// null — вне облачного режима (нет api либо нет сессии).
  Future<String?> ensureCloudId(Project p) async {
    final token = await _cloudToken();
    if (token == null) return null;
    final items = await api!.list(token);
    final existing = _findByName(items, p.name);
    if (existing != null) return existing['id'] as String;
    final created = await api!.create(token, p.name, p.toJson());
    return created['id'] as String;
  }

  /// Загрузить исходник в облако (§12.5: picker → multipart → метаданные);
  /// возвращает `file_id` либо null, если облачный режим не активен.
  Future<String?> uploadSource(
      Project p, String fileName, List<int> bytes) async {
    final token = await _cloudToken();
    if (token == null) return null;
    final cloudId = await ensureCloudId(p);
    if (cloudId == null) return null;
    final res = await api!.uploadFile(token, cloudId, fileName, bytes);
    final id = res['file_id'];
    return id is String && id.isNotEmpty ? id : null;
  }
}
