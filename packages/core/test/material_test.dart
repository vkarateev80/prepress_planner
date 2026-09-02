// Тесты расчёта материала — порт cam_material/tests/test_material_calc.py
// (значения эталонов перенесены 1:1, допуски как в Python-тестах).
import 'dart:math' as math;

import '../tool/test_utils.dart';
import '../lib/src/model/params.dart';
import '../lib/src/calculator/material.dart';

bool intListEq(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

void testRapport() {
  expectNear(computeRapportValue(96, 3.175), 304.8, 'rapport Z*CP', eps: 1e-9);
  expectEq(computeRapportValue(96, 3.175, manual: 300.0), 300.0,
      'ручной раппорт 300');
  expectEq(computeRapportValue(100, 2.5), 250.0, 'rapport 100*2.5');
  ok('rapport');
}

void testGearInfo() {
  final g = gearInfo(96, 3.175, 0.48);
  expectNear(g.rapport, 304.8, 'rapport', eps: 1e-6);
  expectNear(g.dPitch, 304.8 / math.pi, 'dPitch', eps: 1e-3);
  expectNear(g.dCyl, 304.8 / math.pi - 0.96, 'dCyl', eps: 1e-3);
  ok('gear_info');
}

void testRowCandidates() {
  // этикетка 30 мм, мин. зазор 3 мм -> макс. 304.8 // 33 = 9 рядов
  final cands = rowCandidates(304.8, 30.0, 3.0);
  expect(intListEq(cands, [for (var i = 1; i <= 9; i++) i]),
      'rowCandidates 1..9, получено $cands');
  // этикетка не влезает
  expect(rowCandidates(304.8, 400.0, 3.0).isEmpty,
      'rowCandidates: 400 мм не влезает');
  ok('row_candidates');
}

void testPickRows() {
  // ближайший зазор к 3.0: r=9 даёт gap=3.8667, r=8 даёт 8.1 -> выбираем 9
  expectEq(pickRows(304.8, 30.0, 3.0, 3.0), 9, 'pickRows к 3.0 -> 9');
  expectEq(pickRows(304.8, 30.0, 8.0, 3.0), 8, 'pickRows к 8.0 -> 8');
  expect(pickRows(304.8, 400.0, 3.0, 3.0) == null,
      'pickRows: 400 мм -> null');
  ok('pick_rows');
}

void testColCandidates() {
  // ширина 300, этикетка 50, зазор 3 -> макс. (300+3)//53 = 5 колонок
  final cands = colCandidates(300.0, 50.0, 3.0);
  expect(intListEq(cands, [1, 2, 3, 4, 5]),
      'colCandidates 1..5, получено $cands');
  expect(colCandidates(300.0, 400.0, 3.0).isEmpty,
      'colCandidates: 400 мм не влезает');
  ok('col_candidates');
}

LayoutParams mainParams() => LayoutParams(
      labelW: 50,
      labelH: 30,
      gapX: 3,
      gapY: 3,
      zTeeth: 96,
      cp: 3.175,
      cylWidth: 300,
      webWidth: 300,
      minGap: 3,
      mode: 'count',
      count: 5000,
    );

void testComputeCountMode() {
  final r = computeMaterialAuto(mainParams());
  expect(r.error == null, r.error ?? 'расчёт не удался');
  expectEq(r.rows, 9, 'rows');
  expectEq(r.cols, 5, 'cols');
  expectNear(r.gapYActual, 304.8 / 9 - 30, 'gapYActual', eps: 1e-3);
  expectEq(r.perRev, 45, 'perRev');
  expectEq(r.revs, 112, 'revs');
  expectNear(r.length, 112 * 304.8, 'length', eps: 0.01);
  expectEq(r.count, 5040, 'count');
  expectEq(r.countRequested, 5000, 'countRequested');
  expectEq(r.excessLabels, 40, 'excessLabels');
  expectNear(r.usedWidth, 262.0, 'usedWidth', eps: 1e-3);
  expectNear(r.areaMm2, 112 * 304.8 * 300, 'areaMm2', eps: 1.0);
  expectNear(r.wastePct, 26.18, 'wastePct', eps: 0.01);
  expectNear(r.perLabelArea, 2032.0, 'perLabelArea', eps: 0.01);
  ok('compute_count_mode');
}

void testComputeLengthMode() {
  final p = mainParams().copyWith(mode: 'length', length: 10000);
  final r = computeMaterialAuto(p);
  expect(r.error == null, r.error ?? 'расчёт не удался');
  expectEq(r.revs, 32, 'revs');
  expectNear(r.length, 32 * 304.8, 'length', eps: 0.01);
  expectEq(r.count, 32 * 45, 'count');
  // удельный расход не зависит от режима при тех же rows/cols
  expectNear(r.perLabelArea, 2032.0, 'perLabelArea', eps: 0.01);
  ok('compute_length_mode');
}

void testComputeErrors() {
  // этикетка не влезает в раппорт
  final p1 = LayoutParams(
      labelW: 50, labelH: 400, zTeeth: 96, cp: 3.175, minGap: 3,
      mode: 'count', count: 100);
  expect(computeMaterialAuto(p1).error != null,
      'ошибка: 400 мм не влезает в раппорт');
  // этикетка не влезает в ширину
  final p2 = LayoutParams(
      labelW: 400, labelH: 30, zTeeth: 96, cp: 3.175,
      cylWidth: 300, webWidth: 300, minGap: 3, mode: 'count', count: 100);
  expect(computeMaterialAuto(p2).error != null,
      'ошибка: 400 мм не влезает в ширину');
  // длина меньше раппорта
  final p3 = LayoutParams(
      labelW: 50, labelH: 30, zTeeth: 96, cp: 3.175,
      minGap: 3, mode: 'length', length: 100);
  expect(computeMaterialAuto(p3).error != null,
      'ошибка: длина меньше раппорта');
  ok('compute_errors');
}

void testRotationExplicit() {
  // явный поворот меняет rows/cols местами
  final p = mainParams();
  final rNorm = computeMaterial(p, rows: 9, cols: 5, rotated: false);
  final rRot = computeMaterial(p, rows: 5, cols: 9, rotated: true);
  expectEq(rNorm.labelW, 50.0, 'labelW обычная');
  expectEq(rNorm.labelH, 30.0, 'labelH обычная');
  expectEq(rRot.labelW, 30.0, 'labelW повёрнутая');
  expectEq(rRot.labelH, 50.0, 'labelH повёрнутая');
  expectEq(rRot.perRev, 45, 'perRev повёрнутая');
  expect(rRot.error == null, rRot.error ?? 'rotated не удался');
  ok('rotation_explicit');
}

void main() {
  testRapport();
  testGearInfo();
  testRowCandidates();
  testPickRows();
  testColCandidates();
  testComputeCountMode();
  testComputeLengthMode();
  testComputeErrors();
  testRotationExplicit();
  // ignore: avoid_print
  print('Все тесты расчёта материала пройдены.');
}
