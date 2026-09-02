/// Расчёт расхода материала — порт 1:1 математики `cam_material/src/calculator/material.py`.
///
/// Чистые функции: входные параметры -> результат. Никакой зависимости от GUI.
///
/// Основная математика:
///     rapport   = Z * CP                     (или ручной ввод)
///     dPitch    = rapport / pi
///     dCyl      = dPitch - 2 * undercut
///     stepX     = labelW + gapX
///     stepY(r)  = rapport / r                (r рядов; шов обязан сходиться!)
///     gapYAct   = stepY(r) - labelH          (>= minGap)
///     cols      <= floor((W_eff + gapX) / (labelW + gapX)),  W_eff = min(цилиндр, полотно)
///     perRev    = rows * cols
///     режим 'count':  revs = ceil(N / perRev),        length = revs * rapport
///     режим 'length': revs = floor(L / rapport),        count  = revs * perRev
///     area      = length * webWidth                    (полотно = длина * ширина полотна)
///     waste%    = (1 - S_used / area) * 100
library;

import 'dart:math' as math;
import '../model/params.dart';

// ============================================================
// Округление (как round(x, n) в Python)
// ============================================================

double _round(double v, int n) {
  final f = math.pow(10.0, n).toDouble();
  return (v * f).roundToDouble() / f;
}

double _round4(double v) => _round(v, 4);
double _round2(double v) => _round(v, 2);

// ============================================================
// Геометрия шестерни
// ============================================================

/// Раппорт шестерни, мм. Если [manual] > 0 — ручной раппорт вместо Z*CP.
double computeRapportValue(int z, double cp, {double manual = 0}) {
  if (manual > 0) return manual;
  return z.toDouble() * cp;
}

/// Параметры шестерни/цилиндра: раппорт, делительный диаметр, диаметр тела.
class GearInfo {
  final double rapport;
  final double dPitch;
  final double dCyl;
  const GearInfo(this.rapport, this.dPitch, this.dCyl);
}

GearInfo gearInfo(int z, double cp, double undercut, {double manual = 0}) {
  final rapport = computeRapportValue(z, cp, manual: manual);
  final dPitch = rapport / math.pi;
  final dCyl = dPitch - 2.0 * undercut;
  return GearInfo(_round4(rapport), _round4(dPitch), _round4(dCyl));
}

// ============================================================
// Кандидаты рядов и колонок
// ============================================================

/// Допустимое число рядов r: шаг step = rapport / r обязан давать фактический
/// зазор >= minGap (условие сходимости шва на цилиндре).
/// Возвращает отсортированный по возрастанию список r.
List<int> rowCandidates(double rapport, double labelH, double minGap) {
  if (rapport <= 0 || labelH <= 0) return const [];
  final maxRows = (rapport / (labelH + minGap)).floor();
  return [for (var i = 1; i <= maxRows; i++) i];
}

/// Допустимое число колонок c: используемая ширина
/// c*labelW + (c-1)*gapX не превышает limitWidth (мин. цилиндр/полотно).
List<int> colCandidates(double limitWidth, double labelW, double gapX) {
  if (limitWidth <= 0 || labelW <= 0) return const [];
  final maxCols = ((limitWidth + gapX) / (labelW + gapX)).floor();
  return [for (var i = 1; i <= maxCols; i++) i];
}

/// Выбор числа рядов, ближайшего к желаемому зазору [gapY]
/// (с учётом сходимости шва). null — этикетка не влезает в раппорт.
int? pickRows(double rapport, double labelH, double gapY, double minGap) {
  final candidates = rowCandidates(rapport, labelH, minGap);
  if (candidates.isEmpty) return null;
  var best = candidates.first;
  double? bestDiff;
  for (final r in candidates) {
    final gapActual = rapport / r - labelH;
    final diff = (gapActual - gapY).abs();
    if (bestDiff == null || diff < bestDiff) {
      best = r;
      bestDiff = diff;
    }
  }
  return best;
}

// ============================================================
// Основной расчёт
// ============================================================

/// Результат полного расчёта раскроя. [error] != null — расчёт невозможен
/// (поля результата при ошибке нулевые).
class MaterialResult {
  final String? error; // null = успех
  final double labelW, labelH, gapX, gapYRequested, gapYActual, stepX, stepY;
  final int rows, cols;
  final double usedWidth, webMin;
  final int perRev, revs, count, countRequested, excessLabels;
  final double rapport, dPitch, dCyl, length, webWidth;
  final double areaMm2, areaM2, usedAreaMm2, wastePct, perLabelArea;
  final String mode;
  final bool rotated;

  const MaterialResult({
    this.error,
    this.labelW = 0,
    this.labelH = 0,
    this.gapX = 0,
    this.gapYRequested = 0,
    this.gapYActual = 0,
    this.stepX = 0,
    this.stepY = 0,
    this.rows = 0,
    this.cols = 0,
    this.usedWidth = 0,
    this.webMin = 0,
    this.perRev = 0,
    this.revs = 0,
    this.count = 0,
    this.countRequested = 0,
    this.excessLabels = 0,
    this.rapport = 0,
    this.dPitch = 0,
    this.dCyl = 0,
    this.length = 0,
    this.webWidth = 0,
    this.areaMm2 = 0,
    this.areaM2 = 0,
    this.usedAreaMm2 = 0,
    this.wastePct = 0,
    this.perLabelArea = 0,
    this.mode = '',
    this.rotated = false,
  });

  /// Результат-ошибка: поля нулевые, [error] заполнен.
  factory MaterialResult.withError(String message) => MaterialResult(error: message);
}

/// Полный расчёт раскроя.
///
/// Если rows/cols не заданы — автоматический выбор:
///   rows — ближайший к желаемому зазору gapY;
///   cols — максимально возможное число колонок.
/// Возвращает MaterialResult; при ошибке error != null.
MaterialResult computeMaterial(LayoutParams p,
    {int? rows, int? cols, bool rotated = false}) {
  final labelW = rotated ? p.labelH : p.labelW;
  final labelH = rotated ? p.labelW : p.labelH;
  final gapX = p.gapX;
  final gapY = p.gapY;
  final minGap = p.minGap;

  final rapport = computeRapportValue(p.zTeeth, p.cp, manual: p.rapportManual);
  if (rapport <= 0) {
    return MaterialResult.withError(
        'Раппорт должен быть больше нуля (проверьте Z и CP).');
  }

  var r = rows;
  if (r == null) r = pickRows(rapport, labelH, gapY, minGap);
  if (r == null || r < 1) {
    return MaterialResult.withError(
        'Этикетка высотой ${labelH.toStringAsFixed(2)} мм не влезает в раппорт '
        '${rapport.toStringAsFixed(2)} мм (даже с минимальным зазором '
        '${minGap.toStringAsFixed(2)} мм).');
  }

  final stepY = rapport / r;
  final gapYActual = stepY - labelH;
  if (gapYActual < minGap - 1e-9) {
    return MaterialResult.withError(
        'Фактический зазор по Y (${gapYActual.toStringAsFixed(3)} мм) меньше '
        'минимального (${minGap.toStringAsFixed(2)} мм).');
  }

  final effectiveWidth =
      p.cylWidth < p.webWidth ? p.cylWidth : p.webWidth;
  var c = cols;
  if (c == null) {
    final cands = colCandidates(effectiveWidth, labelW, gapX);
    c = cands.isEmpty ? 0 : cands.last;
  }
  if (c < 1) {
    return MaterialResult.withError(
        'Этикетка шириной ${labelW.toStringAsFixed(2)} мм не влезает в ширину '
        '${effectiveWidth.toStringAsFixed(2)} мм (цилиндр/полотно).');
  }

  final stepX = labelW + gapX;
  final usedWidth = c * labelW + (c - 1) * gapX;
  if (usedWidth > effectiveWidth + 1e-9) {
    return MaterialResult.withError(
        'Используемая ширина ${usedWidth.toStringAsFixed(2)} мм превышает '
        'доступную ${effectiveWidth.toStringAsFixed(2)} мм.');
  }

  final perRev = r * c;

  int revs;
  double lengthActual;
  int totalLabels;
  if (p.mode == 'length') {
    final length = p.length < 0 ? 0.0 : p.length;
    revs = rapport > 0 ? (length / rapport).floor() : 0;
    if (revs < 1) {
      return MaterialResult.withError(
          'Длина полотна ${length.toStringAsFixed(1)} мм меньше одного '
          'раппорта (${rapport.toStringAsFixed(2)} мм).');
    }
    lengthActual = revs * rapport;
    totalLabels = revs * perRev;
  } else {
    final count = p.count < 0 ? 0 : p.count;
    revs = perRev > 0 ? (count + perRev - 1) ~/ perRev : 0;
    lengthActual = revs * rapport;
    totalLabels = revs * perRev;
  }

  final area = lengthActual * p.webWidth;
  final usedArea = totalLabels * labelW * labelH;
  final wastePct = area > 0 ? (1.0 - usedArea / area) * 100.0 : 0.0;
  final perLabelArea = totalLabels > 0 ? area / totalLabels : 0.0;

  final gear = gearInfo(p.zTeeth, p.cp, p.undercut, manual: p.rapportManual);

  // Python: count_requested = params.count (режим count) / None (режим length).
  // В Dart поле int; для режима length используется 0 (не применимо).
  final requested = p.mode == 'count' ? p.count : 0;
  final excess = totalLabels - requested;
  final round4 = _round4;
  final round2 = _round2;

  return MaterialResult(
    labelW: round4(labelW),
    labelH: round4(labelH),
    gapX: round4(gapX),
    gapYRequested: round4(gapY),
    rows: r,
    cols: c,
    stepX: round4(stepX),
    stepY: round4(stepY),
    gapYActual: round4(gapYActual),
    usedWidth: round4(usedWidth),
    webMin: round4(usedWidth),
    perRev: perRev,
    rapport: gear.rapport,
    dPitch: gear.dPitch,
    dCyl: gear.dCyl,
    mode: p.mode,
    count: totalLabels,
    countRequested: requested,
    revs: revs,
    length: round2(lengthActual),
    webWidth: p.webWidth,
    areaMm2: round2(area),
    areaM2: round4(area / 1e6),
    usedAreaMm2: round2(usedArea),
    wastePct: round2(wastePct),
    perLabelArea: round2(perLabelArea),
    excessLabels: excess < 0 ? 0 : excess,
    rotated: rotated,
  );
}

/// Расчёт с автоматическим выбором рядов/колонок.
MaterialResult computeMaterialAuto(LayoutParams p) => computeMaterial(p);
