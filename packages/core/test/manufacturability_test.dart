// Тесты анализа технологичности (аг.06): порт test_manufacturability.py
// + фикстуры quadroring/petlya_open_artifacts.
import '../tool/test_utils.dart';
import '../lib/io.dart';
import '../lib/src/parser/dxf_parser.dart';
import '../lib/src/manufacturability/geometry_checks.dart';
import '../lib/src/manufacturability/analyzer.dart';
import '../lib/src/model/cam_path.dart';
import '../lib/src/model/vec2.dart';
import '../lib/src/model/params.dart';

String fx(String name) => '../../fixtures/$name';

ManufacturingParams params(
        {double tolerance = 2.0,
        double minLoopArea = 1.0,
        double minRadius = 0.2,
        double minGap = 0.5}) =>
    ManufacturingParams(
        tolerance: tolerance,
        minLoopArea: minLoopArea,
        minRadius: minRadius,
        minGap: minGap);

CamPath _polyline(List<(double, double)> pts,
        {bool closed = false, String layer = 'T'}) =>
    CamPath(pts.map((p) => Vec2(p.$1, p.$2)).toList(),
        isClosed: closed, layerName: layer);

/// Квадрат как в Python square(): с явным дублем первой точки при closed.
CamPath _square(double x0, double y0, double size,
        {bool closed = true, String layer = 'TEST'}) {
  final pts = <(double, double)>[
    (x0, y0),
    (x0 + size, y0),
    (x0 + size, y0 + size),
    (x0, y0 + size),
    if (closed) (x0, y0),
  ];
  return _polyline(pts, closed: closed, layer: layer);
}

void main() {
  // ===== 1. Реальный файл с артефактами: open (error) =====
  // petlya_open_artifacts.dxf: большой разомкнутый контур (SPLINE) + обрывки.
  final raw = DxfParser().parse(fx('petlya_open_artifacts.dxf'));
  final report = analyzeManufacturability(raw, params());
  final openIssues =
      report.issues.where((i) => i.kind == 'open').toList();
  expect(openIssues.isNotEmpty, 'petlya_open: есть open');
  expect(openIssues.every((i) => i.severity == 'error'),
      'petlya_open: open -> error');
  expect(openIssues.every((i) => i.fixable), 'petlya_open: open fixable');
  expectEq(report.ok, false, 'petlya_open: ok=false');
  expectEq(report.counts['error'], openIssues.length,
      'petlya_open: ошибки — только open');
  expect(report.verdict == 'Требует исправлений (${report.counts['error']} критич.)',
      'petlya_open: вердикт «Требует исправлений (N критич.)», получено: '
          '${report.verdict}');
  expect(report.issues.first.kind == 'open',
      'petlya_open: первая проверка — open (порядок как в Python)');
  expect(report.issues.first.message.contains('Разомкнутый контур'),
      'petlya_open: русский текст open');
  ok('analysis: petlya_open_artifacts.dxf');

  // ===== 2. applyIssueFix(open) -> повторный analyze: open исчез =====
  final openIssue = openIssues.first;
  final fixed = applyIssueFix(raw, openIssue, params());
  expect(fixed.isNotEmpty, 'fix open: лечение дало контуры');
  final rep2 = analyzeManufacturability(fixed, params());
  expect(
      rep2.issues.where((i) => i.kind == 'open').isEmpty,
      'fix open: после лечения open больше нет');
  ok('fix: open -> healGeometry');

  // ===== 3. healGeometry: все контуры замкнуты (кроме HEALED_TAIL) =====
  final healed = healGeometry(raw, params());
  final notClosed = healed
      .where((p) => !p.isClosed && p.layerName != 'HEALED_TAIL')
      .toList();
  expect(notClosed.isEmpty,
      'heal: все контуры замкнуты (кроме HEALED_TAIL) — '
          '${notClosed.length} незамкнутых');
  ok('heal: petlya_open_artifacts.dxf');

  // ===== 4. quadroring.dxf (чистый массив): нет error =====
  final qr = DxfParser().parse(fx('quadroring.dxf'));
  final qrep = analyzeManufacturability(qr, params());
  expectEq(qrep.counts['error'], 0,
      'quadroring: нет error (получено ${qrep.issues.map((i) => i.kind).toList()})');
  expect(qrep.ok, 'quadroring: ok=true');
  ok('analysis: quadroring.dxf (${qrep.issues.length} issue)');

  // ===== 5. Пыль: квадрат 0.3x0.3 при minLoopArea=1.0 =====
  final dust = _square(0, 0, 0.3); // 0.09 мм²
  final big = _square(10, 0, 10); // 100 мм²
  final dRep = analyzeManufacturability([dust, big], params());
  final dustIssues = dRep.issues.where((i) => i.kind == 'dust').toList();
  expectEq(dustIssues.length, 1, 'пыль: ровно одна');
  expectEq(dustIssues.first.index, 0, 'пыль: индекс 0');
  expectEq(dustIssues.first.severity, 'warning', 'пыль: warning');
  expect(dustIssues.first.fixable, 'пыль: fixable');
  final cleaned = removeDustPaths([dust, big], 1.0);
  expectEq(cleaned.length, 1, 'removeDustPaths: остался большой');
  expect(identical(cleaned[0], big), 'removeDustPaths: объект сохранён');
  // applyIssueFix(dust) тоже удаляет.
  final fixedDust = applyIssueFix([dust, big], dustIssues.first, params());
  expectEq(fixedDust.length, 1, 'applyIssueFix(dust): остался большой');
  ok('dust: 0.3x0.3 при minLoopArea=1.0');

  // ===== 6. Острый угол: 45° (порт check_sharp_corners) =====
  // Длинные стороны (10 мм): r_max = 7.07*tan(22.5°) ~ 2.93 >= 0.2 -> suggestion.
  final tri45 =
      _polyline([(0, 0), (10, 0), (5, 5), (0, 0)], closed: true); // углы 45°
  final p45 = params(minLoopArea: 0, minRadius: 0.2);
  final sharp45 = analyzeManufacturability([tri45], p45)
      .issues
      .where((i) => i.kind == 'sharp_corner')
      .toList();
  expect(sharp45.isNotEmpty, '45°: острый угол найден');
  expect(sharp45.every((i) => i.severity == 'suggestion'),
      '45° длинные стороны: r_max >= 0.2 -> suggestion');
  // Короткие стороны (0.5 мм): r_max = 0.354*tan(22.5°) ~ 0.147 < 0.2 -> error.
  final triSmall = _polyline([(0, 0), (0.5, 0), (0.25, 0.25), (0, 0)],
      closed: true);
  final sharpSmall = analyzeManufacturability([triSmall], p45)
      .issues
      .where((i) => i.kind == 'sharp_corner')
      .toList();
  expect(sharpSmall.any((i) => i.severity == 'error'),
      '45° короткие стороны: r_max < 0.2 -> error');
  ok('sharp_corner: 45°');

  // ===== 7. Пустой/вырожденный вход не падает =====
  final empty = analyzeManufacturability(const [], params());
  expectEq(empty.issues.length, 0, 'пустой вход: нет issues');
  expect(empty.ok, 'пустой вход: ok=true');
  expectEq(empty.verdict, 'Технологично', 'пустой вход: вердикт');
  expect(healGeometry(const [], params()).isEmpty, 'heal: пустой вход');
  expect(removeDustPaths(const [], 1.0).isEmpty, 'dust: пустой вход');
  // Вырожденные пути (0/1/2 точек) не роняют ни одну проверку.
  final degen = [
    CamPath(const [], isClosed: false),
    CamPath(const [Vec2(1, 1)], isClosed: false),
    CamPath(const [Vec2(0, 0), Vec2(0, 0)], isClosed: false),
    CamPath(const [Vec2(0, 0), Vec2(0, 0)], isClosed: true),
  ];
  analyzeManufacturability(degen, params());
  checkOpenPaths(degen);
  checkDust(degen, 1.0);
  checkDust(degen, 0.0); // minLoopArea <= 0 отключает проверку
  checkIntersectionsDuplicates(degen);
  checkSharpCorners(degen, 0.2);
  checkSmallGaps(degen, 0.5);
  ok('устойчивость: пустой/вырожденный вход');

  // ===== 8. Точные числовые границы (эталон test_sharp_corner_analysis) =====
  // Острый треугольник: углы у основания ~5.7°.
  final tri = _polyline([(0, 0), (10, 0), (5, 0.5), (0, 0)], closed: true);
  final bigR = checkSharpCorners([tri], 0.5);
  expect(bigR.any((i) => i.kind == 'sharp_corner' && i.severity == 'error'),
      '5.7° при minRadius=0.5: error (r_max~0.251 < 0.5)');
  final smallR = checkSharpCorners([tri], 0.01);
  expect(!smallR.any((i) => i.severity == 'error'),
      '5.7° при minRadius=0.01: без error');
  expect(smallR.any((i) => i.severity == 'suggestion'),
      '5.7° при minRadius=0.01: есть suggestion');
  ok('sharp_corner: 5.7° числовые границы');

  // ===== 9. Разомкнутые: эталон test_open_path_detected / closed_ok =====
  expect(checkOpenPaths([_square(0, 0, 10, closed: false)])
          .any((i) => i.kind == 'open'),
      'open: незамкнутый квадрат');
  expectEq(checkOpenPaths([_square(0, 0, 10, closed: true)]).length, 0,
      'open: замкнутый квадрат чист');
  ok('open: закрытые/открытые');

  // ===== 10. Малый зазор: эталон test_small_gap_detected =====
  final a = _square(0, 0, 10);
  final b = _square(10.3, 0, 10); // зазор 0.3 мм
  expect(checkSmallGaps([a, b], 0.5).any((i) => i.kind == 'small_gap'),
      'small_gap: 0.3 мм < 0.5 найден');
  expectEq(checkSmallGaps([a, b], 0.1).length, 0,
      'small_gap: 0.3 мм >= 0.1 не найден');
  expect(checkSmallGaps([a, b], 0.5).first.message.contains('Зазор 0.300'),
      'small_gap: текст с зазором');
  ok('small_gap: 0.3 мм между контурами');

  // ignore: avoid_print
  print('Все тесты технологичности пройдены.');
}
