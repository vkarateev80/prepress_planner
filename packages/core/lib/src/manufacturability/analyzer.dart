/// Анализатор технологичности (порт cam_material
/// src/manufacturability/analyzer.py, 1:1): собирает проверки в отчёт,
/// формирует вердикт и предоставляет авто-исправления.
library;

import '../model/cam_path.dart';
import '../model/params.dart';
import '../model/issue.dart';
import '../healer/morphology.dart';
import '../optimizer/topology.dart';
import 'geometry_checks.dart';

/// Результат полного анализа технологичности.
class AnalysisReport {
  final List<Issue> issues;
  final String verdict; // «Технологично» | «Внимание (N предупреждений)» | «Требует исправлений (N критич.)»
  final Map<String, int> counts; // error/warning/suggestion
  final bool ok;

  const AnalysisReport({
    required this.issues,
    required this.verdict,
    required this.counts,
    required this.ok,
  });
}

/// Полный анализ технологичности импортированной геометрии.
///
/// Порядок проверок — как в Python analyzer.py: open → dust →
/// intersection/duplicate → sharp_corner → small_gap.
AnalysisReport analyzeManufacturability(
    List<CamPath> paths, ManufacturingParams p) {
  final raw = <Issue>[
    ...checkOpenPaths(paths),
    ...checkDust(paths, p.minLoopArea),
    ...checkIntersectionsDuplicates(paths),
    ...checkSharpCorners(paths, p.minRadius),
    ...checkSmallGaps(paths, p.minGap),
  ];

  final counts = {'error': 0, 'warning': 0, 'suggestion': 0};
  for (final it in raw) {
    counts[it.severity] = (counts[it.severity] ?? 0) + 1;
  }

  final String verdict;
  final bool ok;
  if (counts['error']! > 0) {
    verdict = 'Требует исправлений (${counts['error']} критич.)';
    ok = false;
  } else if (counts['warning']! > 0) {
    verdict = 'Внимание (${counts['warning']} предупреждений)';
    ok = true;
  } else {
    verdict = 'Технологично';
    ok = true;
  }

  return AnalysisReport(issues: raw, verdict: verdict, counts: counts, ok: ok);
}

// ============================================================
// Авто-исправления
// ============================================================

/// Морфологическое лечение: замыкание разрывов, нормализация пересечений.
/// MorphologicalHealer(tolerance, minLoopArea) → TopologicalOptimizer(0.001).
List<CamPath> healGeometry(List<CamPath> paths, ManufacturingParams p) {
  final healer = MorphologicalHealer(
      tolerance: p.tolerance, minLoopArea: p.minLoopArea);
  const optimizer = TopologicalOptimizer(simplifyTolerance: 0.001);
  return optimizer.optimize(healer.heal(paths));
}

/// Удаление контуров-«пыли» (исходные объекты сохраняются).
List<CamPath> removeDustPaths(List<CamPath> paths, double minLoopArea) =>
    [for (final path in paths) if (!isDust(path, minLoopArea)) path];

/// Применяет авто-исправление для одной проблемы.
/// Возвращает новую геометрию (для неисправимых — исходную).
List<CamPath> applyIssueFix(
    List<CamPath> paths, Issue issue, ManufacturingParams p) {
  if (issue.kind == 'dust') {
    return removeDustPaths(paths, p.minLoopArea);
  }
  if (issue.kind == 'open' ||
      issue.kind == 'intersection' ||
      issue.kind == 'duplicate') {
    return healGeometry(paths, p);
  }
  return paths;
}
