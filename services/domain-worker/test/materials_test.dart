// Сериализация `project_state.json v2`: совместимость с функциями приложения
// (`app/lib/src/projects/project.dart`) и полнота серверных секций.
//
// Запуск:  dart test/materials_test.dart   (из services/domain-worker)
library;

import 'dart:convert';

import 'package:prepress_core/prepress_core.dart';

import '../lib/domain_worker.dart';
import '../tool/test_utils.dart';

void main() {
  // ===== 1. Раскрой и ТЭО через домен напрямую (та же среда, что у воркера) =====
  {
    final params = layoutParamsFromJson(null);
    expectEq(params.labelW, 50.0, 'дефолт layoutParamsFromJson: labelW = 50');
    expectEq(params.count, 5000, 'дефолт layoutParamsFromJson: count = 5000');
    expectEq(params.zTeeth, 96, 'дефолт layoutParamsFromJson: zTeeth = 96');

    final calc = computeMaterialAuto(params);
    final json = materialResultToJson(calc);
    expectNear(json['wastePct'] as double, 26.18, 'materialResultToJson: '
        'wastePct', eps: 0.005);
    expectNear(json['perLabelArea'] as double, 2032.0,
        'materialResultToJson: perLabelArea', eps: 0.005);
    expectEq(json['rows'], 9, 'materialResultToJson: rows');
    expectEq(json['cols'], 5, 'materialResultToJson: cols');
    expect(json.containsKey('countRequested'),
        'materialResultToJson (full): есть countRequested');
    final compact = materialResultToJson(calc, full: false);
    expect(!compact.containsKey('countRequested'),
        'materialResultToJson (compact): как в массиве variants UI');
    expect(compact.containsKey('perLabelArea'),
        'materialResultToJson (compact): perLabelArea сохраняется');
    ok('materialResultToJson: полный и компактный (UI-совместимый) вид');
  }

  // ===== 2. Round-trip геометрии: camPathToJson → camPathFromJson =====
  {
    final path = CamPath(
      [Vec2(0, 0), Vec2(10, 0), Vec2(10, 5), Vec2(0, 5)],
      isClosed: true,
      layerName: 'CUT',
    );
    final json = camPathToJson(path);
    expectEq(json['closed'], true, 'camPathToJson: closed');
    expectEq(json['layer'], 'CUT', 'camPathToJson: layer');
    expectEq((json['points'] as List).length, 4, 'camPathToJson: точек 4');
    final back = camPathFromJson(jsonDecode(jsonEncode(json)) as Map<String, dynamic>);
    expectEq(back.points.length, 4, 'camPathFromJson: точек 4');
    expectNear(back.points[2].x, 10.0, 'camPathFromJson: x сохранён');
    expectEq(back.layerName, 'CUT', 'camPathFromJson: слой сохранён');
    expect(back.isClosed, 'camPathFromJson: замкнутость сохранена');
    ok('round-trip CamPath (points/closed/layer)');
  }

  // ===== 3. Issue → JSON: русские текст и рекомендация =====
  {
    const issue = Issue(
      kind: 'open',
      severity: 'warning',
      points: [Vec2(1, 2)],
      message: 'Контур не замкнут: разрыв 4.20 мм.',
      suggestion: 'Замкните контур вручную или исправьте его в списке ошибок.',
      fixable: true,
      index: 7,
    );
    final j = issueToJson(issue);
    expectEq(j['kind'], 'open', 'issueToJson: kind');
    expectEq(j['severity'], 'warning', 'issueToJson: severity');
    expectEq(j['fixable'], true, 'issueToJson: fixable');
    expectEq(j['index'], 7, 'issueToJson: index');
    expect((j['message'] as String).contains('не замкнут'),
        'issueToJson: русское сообщение');
    expect((j['suggestion'] as String).isNotEmpty,
        'issueToJson: русская рекомендация');
    ok('issueToJson (русские message/suggestion, маркеры)');
  }

  // ===== 4. Серверные секции: consumption / teo / shape / comparison =====
  {
    final res = runPipeline({
      'stages': ['calc', 'variants', 'teo'],
      'variantsLimit': 5,
      'teoInput': {'toolingCost': 1500, 'markupPct': 10, 'shiftCostPerShift': 3000},
    });
    final json = res.toJson();
    final sections = json; // серверные секции лежат на верхнем уровне
    final teo = (sections['teo'] as Map).cast<String, dynamic>();
    // Ручная сверка: base = material(1024.13) + machine(2528.45) +
    // tooling(1500) + shift(3000) = 8052.58; +10 % наценки → 8857.84 ₽;
    // на 5040 этикеток → 1757.51 ₽/1000.
    expectNear(teo['totalCost'] as double, 8857.84,
        'ТЭО с оснасткой/наценкой/сменой: totalCost', eps: 0.01);
    expectNear(teo['costPer1000'] as double, 1757.51,
        'ТЭО с оснасткой/наценкой/сменой: costPer1000', eps: 0.01);
    expectNear(teo['shiftCost'] as double, 3000.0,
        'ТЭО: стоимость занятой смены учтена', eps: 0.01);
    final consumption =
        (sections['consumption'] as Map).cast<String, dynamic>();
    expectNear(consumption['perLabelMm2'] as double, 2032.0,
        'consumption.perLabelMm2 = 2032.0', eps: 0.005);
    expectEq((sections['shape'] as Map)['kind'] as String, 'rect',
        'shape.kind = rect (как в UI)');
    final cmp = (sections['teoComparison'] as Map).cast<String, dynamic>();
    expectEq(cmp['compared'], 5,
        'teoComparison: сравнение ограничено списком вариантов (limit=5)');
    expect(cmp['bestTeo'] is Map, 'teoComparison: ТЭО лучшего варианта');
    expect(cmp['savingsPer1000'] is num, 'teoComparison: экономия на 1000 шт');
    expect(sections['priceCatalog'] is Map,
        'priceCatalog: использованный каталог отдан клиенту');
    expectEq(((sections['teoInput'] as Map)['toolingCost'] as num), 1500,
        'teoInput: оснастка из запроса попала в расчёт');
    ok('серверные секции ТЭО (consumption/shape/comparison/priceCatalog)');
  }

  // ===== 5. Каталог цен из запроса (сортамент и машина выбираются по id) =====
  {
    final res = runPipeline({
      'stages': ['teo'],
      'priceCatalog': {
        'currency': '₽',
        'workTime': {'hoursPerShift': 8, 'shiftsPerDay': 2},
        'assortment': [
          {'id': 'paper-sa-80', 'name': 'Бумага (пример)', 'pricePerM2': 100.0},
        ],
        'machines': [
          {
            'id': 'flexo-300',
            'name': 'Флексопечать (пример)',
            'ratePerHour': 5000.0,
            'speedMetersPerMin': 100.0,
            'setupTimeHours': 0.5,
          },
        ],
      },
    });
    expectEq(res.state.teo!.costPer1000, 704.88,
        'каталог из запроса: эталонное ТЭО сохраняется');
    expectEq(res.state.teoInput!['machine']['id'], 'flexo-300',
        'каталог из запроса: машина по умолчанию — первая в каталоге');

    var threw = false;
    try {
      runPipeline({
        'stages': ['teo'],
        'teoInput': {'materialId': 'нет-такого'},
      });
    } on WorkerError catch (e) {
      threw = true;
      expectEq(e.code, 'bad_request', 'неизвестный материал: bad_request');
      expect(e.message.contains('Доступные'),
          'неизвестный материал: перечислены доступные id');
    }
    expect(threw, 'неизвестный материал: ошибка выброшена');
    ok('каталог цен: значения по умолчанию и выбор по id');
  }

  print('ALL PASS: materials_test');
}
