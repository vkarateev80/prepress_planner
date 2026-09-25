/// Чтение параметров домена из JSON (wire-схема совпадает с
/// `app/lib/src/projects/project.dart`: `layoutParamsToJson`/
/// `layoutParamsFromJson`) + дефолты эталонного сценария PRD §10.2.
///
/// Логика разбора — 1:1 с приложением: любое отсутствующее поле берёт
/// дефолт `LayoutParams()` (50×30, зазоры 3, Z=96, CP=3.175, cyl=web=300,
/// N=5000). Именно поэтому запрос `{"stages":["calc"]}` без параметров даёт
/// эталонные 9×5 / N=5040 / 34137.6 мм / 26.18 % / 2032.0 мм².
library;

import 'package:prepress_core/prepress_core.dart';

/// [LayoutParams] из JSON-объекта (ключи как в project_state.json v2).
LayoutParams layoutParamsFromJson(Map<String, dynamic>? j) {
  final m = j ?? const <String, dynamic>{};
  return LayoutParams(
    labelW: (m['labelW'] as num?)?.toDouble() ?? 50,
    labelH: (m['labelH'] as num?)?.toDouble() ?? 30,
    gapX: (m['gapX'] as num?)?.toDouble() ?? 3,
    gapY: (m['gapY'] as num?)?.toDouble() ?? 3,
    zTeeth: (m['zTeeth'] as num?)?.toInt() ?? 96,
    cp: (m['cp'] as num?)?.toDouble() ?? 3.175,
    rapportManual: (m['rapportManual'] as num?)?.toDouble() ?? 0,
    cylWidth: (m['cylWidth'] as num?)?.toDouble() ?? 300,
    webWidth: (m['webWidth'] as num?)?.toDouble() ?? 300,
    undercut: (m['undercut'] as num?)?.toDouble() ?? 0.48,
    minGap: (m['minGap'] as num?)?.toDouble() ?? 3,
    mode: (m['mode'] as String?) ?? 'count',
    count: (m['count'] as num?)?.toInt() ?? 5000,
    length: (m['length'] as num?)?.toDouble() ?? 10000,
  );
}

/// [LayoutParams] → JSON (схема `layoutParamsToJson` приложения).
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

/// [ManufacturingParams] из JSON. Дефолты домена: tolerance 2.0,
/// minLoopArea 1.0, minRadius 0.2, minGap 0.5.
ManufacturingParams manufacturingParamsFromJson(Map<String, dynamic>? j) {
  final m = j ?? const <String, dynamic>{};
  return ManufacturingParams(
    tolerance: (m['tolerance'] as num?)?.toDouble() ?? 2.0,
    minLoopArea: (m['minLoopArea'] as num?)?.toDouble() ?? 1.0,
    minRadius: (m['minRadius'] as num?)?.toDouble() ?? 0.2,
    minGap: (m['minGap'] as num?)?.toDouble() ?? 0.5,
  );
}

/// [ManufacturingParams] → JSON.
Map<String, dynamic> manufacturingParamsToJson(ManufacturingParams p) => {
      'tolerance': p.tolerance,
      'minLoopArea': p.minLoopArea,
      'minRadius': p.minRadius,
      'minGap': p.minGap,
    };

/// Каталог цен: из запроса либо эталонный `PriceCatalog.defaults()`
/// (те же значения, что в UI приложения до правки каталога).
PriceCatalog priceCatalogFromJson(Map<String, dynamic>? j) {
  if (j == null || j.isEmpty) return PriceCatalog.defaults();
  try {
    return PriceCatalog.fromJson(j);
  } catch (e) {
    // Битый каталог не должен «ронять» расчёт: работаем на эталонном.
    return PriceCatalog.defaults();
  }
}
