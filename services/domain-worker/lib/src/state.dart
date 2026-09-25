/// Схема `project_state.json v2` — каноническая сериализация домена.
///
/// Сериализаторы повторяют 1:1 функции приложения
/// (`app/lib/src/projects/project.dart`: `camPathToJson`, `issueToJson`,
/// `patternResultToJson`, `materialResultToJson`, `layoutParamsToJson`) —
/// она и wire-схема, и схема хранения (ADR-2). Дополнительно воркер отдаёт
/// секции, которых в UI-схеме нет: `teo`, `teoComparison`, `consumption`
/// (ТЭО считается на сервере по тому же коду `packages/core`).
library;

import 'package:prepress_core/prepress_core.dart';

import 'params.dart';

/// Версия схемы состояния (ADR-2: `project_state.json v2`).
const int kProjectStateSchemaVersion = 2;

/// Версия воркера — попадает в `metrics.workerVersion` и `/healthz`.
const String kWorkerVersion = '0.1.0';

// ============================================================
// Геометрия и диагностика
// ============================================================

/// [CamPath] → JSON: `{points: [[x,y],…], closed, layer}`.
Map<String, dynamic> camPathToJson(CamPath p) => {
      'points': [
        for (final v in p.points) [v.x, v.y]
      ],
      'closed': p.isClosed,
      'layer': p.layerName,
    };

/// JSON → [CamPath].
CamPath camPathFromJson(Map<String, dynamic> j) {
  final pts = <Vec2>[];
  for (final e in (j['points'] as List? ?? const [])) {
    final a = e as List;
    pts.add(Vec2((a[0] as num).toDouble(), (a[1] as num).toDouble()));
  }
  return CamPath(pts,
      isClosed: j['closed'] == true, layerName: (j['layer'] as String?) ?? '');
}

/// Список путей → JSON-массив.
List<Map<String, dynamic>> camPathsToJson(List<CamPath> paths) =>
    [for (final p in paths) camPathToJson(p)];

/// JSON-массив → список путей.
List<CamPath> camPathsFromJson(Object? raw) {
  final out = <CamPath>[];
  for (final e in (raw as List? ?? const [])) {
    if (e is Map) out.add(camPathFromJson(e.cast<String, dynamic>()));
  }
  return out;
}

/// [Issue] → JSON (русские `message`/`suggestion` из домена).
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

// ============================================================
// Массив (Step & Repeat)
// ============================================================

/// [PatternResult] → JSON.
Map<String, dynamic> patternResultToJson(PatternResult p) => {
      'isArray': p.isArray,
      'masterPaths': camPathsToJson(p.masterPaths),
      'offsets': [
        for (final o in p.offsets) [o.x, o.y]
      ],
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

// ============================================================
// Раскрой и расход
// ============================================================

/// [MaterialResult] → JSON.
///
/// [full] = true (по умолчанию) — полный набор полей (как `calc` в UI-схеме).
/// [full] = false — компактный набор для массива `variants`
/// (`app/lib/src/projects/project.dart` сериализует варианты укороченным
/// списком: error/labelW/labelH/rotated/rows/cols/stepX/stepY/gapYActual/
/// usedWidth/webMin/perRev/revs/count/excessLabels/rapport/dPitch/dCyl/length/
/// webWidth/areaMm2/areaM2/usedAreaMm2/wastePct/perLabelArea/mode — без
/// gapX/gapYRequested/countRequested). Компактный вид сохранён для
/// совместимости wire-формата; полные значения вариантов отдаются отдельно
/// в `variantResults`, чтобы не терять `perLabelArea` и `gapX`.
Map<String, dynamic> materialResultToJson(MaterialResult r,
    {bool full = true}) {
  final base = <String, dynamic>{
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
  if (!full) return base;
  return {
    'error': r.error,
    'labelW': r.labelW,
    'labelH': r.labelH,
    'gapX': r.gapX,
    'gapYRequested': r.gapYRequested,
    'gapYActual': r.gapYActual,
    'rotated': r.rotated,
    'rows': r.rows,
    'cols': r.cols,
    'stepX': r.stepX,
    'stepY': r.stepY,
    'usedWidth': r.usedWidth,
    'webMin': r.webMin,
    'perRev': r.perRev,
    'revs': r.revs,
    'count': r.count,
    'countRequested': r.countRequested,
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
}

/// [Consumption] → JSON (свод «полотно vs чистая площадь формы»).
///
/// Поля названы как в домене (`perLabelMm2`); в UI-эквиваленте это значение
/// показывается как «площадь на этикетку, мм²».
Map<String, dynamic> consumptionToJson(Consumption c) => {
      'areaMm2': c.areaMm2,
      'areaM2': c.areaM2,
      'usedAreaMm2': c.usedAreaMm2,
      'wasteMm2': c.wasteMm2,
      'wastePct': c.wastePct,
      'perLabelMm2': c.perLabelMm2,
      'webMin': c.webMin,
    };

/// [LabelShape] → JSON.
Map<String, dynamic> shapeToJson(LabelShape s) => {
      'kind': s.kind,
      'w': s.w,
      'h': s.h,
      'area': s.area,
      'efficiency': s.efficiency,
    };

// ============================================================
// ТЭО
// ============================================================

/// [TeoResult] → JSON.
Map<String, dynamic> teoResultToJson(TeoResult t) => {
      'error': t.error,
      'runTimeHours': t.runTimeHours,
      'setupTimeHours': t.setupTimeHours,
      'totalTimeHours': t.totalTimeHours,
      'shiftsUsed': t.shiftsUsed,
      'shiftCost': t.shiftCost,
      'machineCost': t.machineCost,
      'materialCost': t.materialCost,
      'toolingCost': t.toolingCost,
      'markupCost': t.markupCost,
      'totalCost': t.totalCost,
      'costPer1000': t.costPer1000,
      'costPerLabel': t.costPerLabel,
      'labelsPerHour': t.labelsPerHour,
      'labelsPerShift': t.labelsPerShift,
      'shiftLoadPct': t.shiftLoadPct,
      'fitsShift': t.fitsShift,
    };

/// Вход ТЭО → JSON (что реально ушло в расчёт: сортамент, машина, ставки).
Map<String, dynamic> teoInputToJson(AssortmentItem material, Machine machine,
        WorkTime workTime, TeoInput input, String currency) =>
    {
      'material': {
        'id': material.id,
        'name': material.name,
        'pricePerM2': material.pricePerM2,
        if (material.minOrderM2 != null) 'minOrderM2': material.minOrderM2,
      },
      'machine': {
        'id': machine.id,
        'name': machine.name,
        'ratePerHour': machine.ratePerHour,
        if (machine.speedMetersPerMin != null)
          'speedMetersPerMin': machine.speedMetersPerMin,
        if (machine.labelsPerHour != null)
          'labelsPerHour': machine.labelsPerHour,
        'setupTimeHours': machine.setupTimeHours,
        'setupMaterialMeters': machine.setupMaterialMeters,
      },
      'workTime': {
        'hoursPerShift': workTime.hoursPerShift,
        'shiftsPerDay': workTime.shiftsPerDay,
      },
      'toolingCost': input.toolingCost,
      'markupPct': input.markupPct,
      'setupMaterialMeters': input.materialSetupMeters,
      'shiftCostPerShift': input.shiftCostPerShift,
      'currency': currency,
    };

// ============================================================
// Состояние проекта
// ============================================================

/// Вычисляемая часть состояния проекта (`project_state.json v2`) плюс
/// серверные секции ТЭО. Поля — как у `Project` в приложении.
class ProjectState {
  String name;
  String inputFile;
  LayoutParams params;
  ManufacturingParams manufacturingParams;
  List<CamPath> rawPaths;
  List<CamPath> healedPaths;
  List<Issue> issues;
  PatternResult? pattern;
  List<CamPath> arrayPaths;
  MaterialResult? calc;
  List<MaterialResult> variants;
  int selectedVariantIndex;

  /// ТЭО выбранного варианта (null — не считалось).
  TeoResult? teo;

  /// Расход по форме для выбранного варианта.
  Consumption? consumption;
  LabelShape? shape;

  /// Сравнение вариантов по себестоимости 1000 шт.
  TeoComparison? comparison;

  /// Вход ТЭО, фактически использованный в расчёте (для аудита).
  Map<String, dynamic>? teoInput;

  /// Каталог цен, использованный в расчёте.
  Map<String, dynamic>? priceCatalog;

  /// Таймстемп состояния (ISO-8601, UTC). null — в канонический JSON не
  /// попадает: домен детерминирован, а «время создания» подставляет
  /// вызывающая сторона (`api` пишет его в БД вместе со state_json).
  DateTime? updatedAt;

  ProjectState({
    this.name = 'Проект',
    this.inputFile = '',
    LayoutParams? params,
    ManufacturingParams? manufacturingParams,
    List<CamPath>? rawPaths,
    List<CamPath>? healedPaths,
    List<Issue>? issues,
    this.pattern,
    List<CamPath>? arrayPaths,
    this.calc,
    List<MaterialResult>? variants,
    this.selectedVariantIndex = 0,
    this.teo,
    this.consumption,
    this.shape,
    this.comparison,
    this.teoInput,
    this.priceCatalog,
    this.updatedAt,
  })  : params = params ?? LayoutParams(),
        manufacturingParams = manufacturingParams ?? ManufacturingParams(),
        rawPaths = rawPaths ?? [],
        healedPaths = healedPaths ?? [],
        issues = issues ?? [],
        arrayPaths = arrayPaths ?? [],
        variants = variants ?? [];

  /// Канонический `project_state.json v2`.
  ///
  /// [includeRawPaths] = false — не отдавать исходную геометрию (экономный
  /// ответ, когда исходник и так есть у клиента; N-3/N-6). Признак отказа
  /// виден в `metrics.rawPathsIncluded`.
  Map<String, dynamic> toProjectStateJson({bool includeRawPaths = true}) => {
        'schemaVersion': kProjectStateSchemaVersion,
        'name': name,
        'inputFile': inputFile,
        'params': layoutParamsToJson(params),
        'rawPaths':
            includeRawPaths ? camPathsToJson(rawPaths) : const <dynamic>[],
        'healedPaths': camPathsToJson(healedPaths),
        'issues': [for (final i in issues) issueToJson(i)],
        'pattern': pattern == null ? null : patternResultToJson(pattern!),
        'arrayPaths': camPathsToJson(arrayPaths),
        'calc': calc == null ? null : materialResultToJson(calc!),
        'variants': [
          for (final v in variants) materialResultToJson(v, full: false)
        ],
        'selectedVariantIndex': selectedVariantIndex,
        if (updatedAt != null)
          'updatedAt': updatedAt!.toUtc().toIso8601String(),
      };

  /// Серверные секции, которых нет в UI-схеме: ТЭО, сравнение, расход, формы.
  Map<String, dynamic> toServerSectionsJson() => {
        'consumption':
            consumption == null ? null : consumptionToJson(consumption!),
        'shape': shape == null ? null : shapeToJson(shape!),
        'teo': teo == null ? null : teoResultToJson(teo!),
        'teoInput': teoInput,
        'teoComparison': comparison == null ? null : comparisonToJson(comparison!),
        'priceCatalog': priceCatalog,
        'manufacturingParams': manufacturingParamsToJson(manufacturingParams),
        // Полные значения вариантов (в `variants` они укорочены ради
        // совместимости со схемой UI — см. materialResultToJson).
        'variantResults': [
          for (final v in variants) materialResultToJson(v, full: true)
        ],
      };
}

/// [TeoComparison] → JSON: лучший вариант, база и экономия.
///
/// Перебор целиком здесь не дублируется: раскладка каждого варианта уже есть
/// в `state.variants` (полные значения — в `variantResults`). `bestIndex` —
/// номер лучшего варианта в ИСХОДНОМ перечислении `enumerateVariants`, он же
/// индекс в `state.variants`; `-1` — ни одного успешного варианта.
Map<String, dynamic> comparisonToJson(TeoComparison c) => {
      'bestIndex': c.bestIndex,
      'bestCostPer1000': c.bestCostPer1000,
      'baseCostPer1000': c.baseCostPer1000,
      'savingsPer1000': c.savingsPer1000,
      'savingsPct': c.savingsPct,
      'compared': c.variants.length,
      'bestTeo':
          c.variants.isEmpty ? null : teoResultToJson(c.variants.first.$2),
    };
