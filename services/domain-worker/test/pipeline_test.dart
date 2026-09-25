// Тесты доменной цепочки domain-worker (без pub.dev: обычный скрипт).
//
// Главный критерий приёмки (PRD §10.2 / N-1): эталонная математика 1:1 —
// отходы 26.18 %, 2032.0 мм²/этикетку, costPer1000 = 704.88 ₽.
//
// Запуск:  dart test/pipeline_test.dart   (из services/domain-worker)
library;

import 'dart:convert';
import 'dart:io';

import '../lib/domain_worker.dart';
import '../tool/test_utils.dart';

String fixture(String name) => '${Directory.current.path}/../../fixtures/$name';

String b64Of(String path) =>
    base64Encode(File(path).readAsBytesSync());

void main() {
  // ===== 1. Только раскрой и ТЭО: эталон PRD §10.2 без файла =====
  {
    final res = runPipeline({'stages': ['calc', 'teo']});
    final state = res.state;
    final calc = state.calc!;
    final teo = state.teo!;
    expectEq(calc.rows, 9, 'раскрой: рядов 9');
    expectEq(calc.cols, 5, 'раскрой: колонок 5');
    expectEq(calc.count, 5040, 'раскрой: всего этикеток 5040');
    expectEq(calc.revs, 112, 'раскрой: оборотов 112');
    expectNear(calc.length, 34137.6, 'раскрой: длина 34137.6 мм', eps: 0.05);
    expectNear(calc.rapport, 304.8, 'раскрой: раппорт 304.8 мм', eps: 0.001);
    expectNear(calc.wastePct, 26.18, 'раскрой: отходы 26.18 %', eps: 0.005);
    expectNear(calc.perLabelArea, 2032.0, 'раскрой: 2032.0 мм²/этикетку',
        eps: 0.005);
    expectNear(teo.costPer1000, 704.88, 'ТЭО: costPer1000 = 704.88 ₽',
        eps: 0.005);
    expectNear(teo.totalCost, 3552.58, 'ТЭО: totalCost = 3552.58', eps: 0.005);
    expectNear(teo.machineCost, 2528.45, 'ТЭО: machineCost = 2528.45',
        eps: 0.005);
    expectNear(teo.materialCost, 1024.13, 'ТЭО: materialCost = 1024.13',
        eps: 0.005);
    expectNear(teo.runTimeHours, 0.0057, 'ТЭО: runTime ≈ 0.0057 ч', eps: 1e-4);
    expect(res.metrics['reference']['checked'] == true,
        'метрики: сценарий распознан как эталонный');
    expect(res.metrics['reference']['passed'] == true,
        'метрики: сверка эталона пройдена');
    ok('эталон раскроя и ТЭО (26.18 % / 2032.0 мм² / 704.88 ₽)');
  }

  // ===== 2. Полная цепочка по файлу: parse → heal/analyze → pattern → … =====
  {
    final res = runPipeline({
      'fileName': 'quadroring.dxf',
      'file_base64': b64Of(fixture('quadroring.dxf')),
      'stages': ['all'],
    });
    final state = res.state;
    expectEq(state.rawPaths.length, 3, 'DXF: 3 контура после разбора');
    expectEq(state.healedPaths.length, 2, 'DXF: 2 контура после лечения');
    expect(state.issues.isNotEmpty, 'DXF: анализ нашёл предупреждение');
    expect(state.issues.first.message.isNotEmpty,
        'DXF: русское сообщение об ошибке геометрии');
    expect(state.calc != null && state.calc!.error == null,
        'DXF: раскрой посчитан без ошибок');
    expect(state.teo != null, 'DXF: ТЭО посчитано');
    expect(state.arrayPaths.isNotEmpty || state.pattern?.isArray == false,
        'DXF: массив либо распознан, либо честно помечен как отсутствующий');
    expect(res.stageResults.containsKey('parse'), 'ответ: секция parse');
    expect(res.stageResults.containsKey('analyze'), 'ответ: секция analyze');
    expect(res.stageResults.containsKey('heal'), 'ответ: секция heal');
    expect(res.stageResults.containsKey('pattern'), 'ответ: секция pattern');
    expect(res.stageResults.containsKey('calc'), 'ответ: секция calc');
    expect(res.stageResults.containsKey('teo'), 'ответ: секция teo');
    ok('полная цепочка по quadroring.dxf (${state.rawPaths.length} → '
        '${state.healedPaths.length} контура)');
  }

  // ===== 3. Отдельные стадии =====
  {
    final request = {
      'fileName': 'quadroring.dxf',
      'file_base64': b64Of(fixture('quadroring.dxf')),
    };
    final analyze = runPipeline({...request, 'stages': ['analyze']});
    expect(analyze.state.calc == null,
        'стадия analyze: раскрой не считается (стадия не запрошена)');
    expect(analyze.state.issues.isNotEmpty, 'стадия analyze: ошибки найдены');

    final calc = runPipeline({...request, 'stages': ['calc']});
    expectEq(calc.state.calc!.rows, 9, 'стадия calc: эталонный раскрой 9×5');
    expect(calc.state.teo == null,
        'стадия calc: ТЭО не считается (стадия не запрошена)');
    expectEq(calc.state.rawPaths.length, 3,
        'стадия calc: переданный макет разобран для state.rawPaths');
    expectEq(calc.metrics['counting']['wastePct'], 26.18,
        'стадия calc: отходы 26.18 % в метриках');

    final variants = runPipeline({
      ...request,
      'stages': ['variants'],
      'variantsLimit': 10,
    });
    expectEq(variants.state.variants.length, 10,
        'стадия variants: limit=10 соблюдён');
    expect(variants.state.variants.first.perLabelArea <=
            variants.state.variants.last.perLabelArea,
        'стадия variants: отсортировано по мм²/этикетку');
    ok('отдельные стадии (analyze / calc / variants)');
  }

  // ===== 4. Готовая геометрия (без файла) и параметры запроса =====
  {
    final square = [
      {
        'points': [
          [0, 0],
          [10, 0],
          [10, 10],
          [0, 10]
        ],
        'closed': true,
        'layer': 'CUT',
      }
    ];
    final res = runPipeline({
      'stages': ['calc', 'teo'],
      'params': {'labelW': 50, 'labelH': 30, 'count': 5000},
      'appState': {'rawPaths': square},
    });
    expectEq(res.state.rawPaths.length, 1,
        'rawPaths из appState: геометрия принята');
    expectNear(res.state.calc!.wastePct, 26.18,
        'параметры запроса: эталон сохраняется', eps: 0.005);
    ok('готовая геометрия в appState + переопределение params');
  }

  // ===== 5. Детерминированность: два прогона дают одинаковый JSON =====
  {
    final request = {
      'stages': ['calc', 'variants', 'teo'],
      'variantsLimit': 20,
      'includeRawPaths': false,
    };
    final a = jsonEncode(runPipeline(request).toJson(includeRawPaths: false));
    final b = jsonEncode(runPipeline(request).toJson(includeRawPaths: false));
    expectEq(a, b, 'детерминированность: одинаковый вход → одинаковый выход');
    final parsed = jsonDecode(a) as Map<String, dynamic>;
    expectEq(parsed['schemaVersion'], 2, 'wire-схема: schemaVersion = 2');
    final state = (parsed['state'] as Map).cast<String, dynamic>();
    expectEq(state['schemaVersion'], 2,
        'project_state.json v2: schemaVersion = 2');
    expect(state['calc'] is Map, 'project_state.json v2: секция calc');
    expect(state['variants'] is List, 'project_state.json v2: секция variants');
    ok('детерминированность и структура project_state.json v2');
  }

  // ===== 6. Русские ошибки =====
  {
    var threw = false;
    try {
      runPipeline({'stages': ['parse']});
    } on WorkerError catch (e) {
      threw = true;
      expectEq(e.code, 'bad_request', 'пустой запрос: код bad_request');
      expect(e.message.contains('макет'), 'пустой запрос: русское сообщение');
    }
    expect(threw, 'пустой запрос: ошибка выброшена');

    threw = false;
    try {
      runPipeline({
        'stages': ['parse'],
        'fileName': 'petlya.eps',
        'file_base64': base64Encode(List<int>.filled(16, 0)),
      });
    } on WorkerError catch (e) {
      threw = true;
      expectEq(e.code, 'unsupported_format',
          'EPS: код unsupported_format (нужна конвертация)');
      expect(e.message.contains('конвертация'),
          'EPS: понятное русское сообщение');
    }
    expect(threw, 'EPS: ошибка выброшена');

    threw = false;
    try {
      runPipeline({
        'stages': ['calc'],
        'params': {'labelW': 1000, 'cylWidth': 300, 'webWidth': 300},
      });
    } on WorkerError catch (e) {
      threw = true;
      expectEq(e.code, 'geometry_error', 'нераскладываемая этикетка: код '
          'geometry_error');
      expect(e.message.isNotEmpty, 'нераскладываемая этикетка: русский текст');
    }
    expect(threw, 'нераскладываемая этикетка: ошибка выброшена');

    threw = false;
    try {
      runPipeline({
        'stages': ['parse'],
        'storage_key': 'org/o/project/p/file/f/1/sha/q.dxf',
      });
    } on WorkerError catch (e) {
      threw = true;
      expectEq(e.code, 'file_not_found',
          'storage_key без байтов: код file_not_found');
      expect(e.message.contains('file_base64'),
          'storage_key без байтов: подсказка, как передать файл');
    }
    expect(threw, 'storage_key без байтов: ошибка выброшена');
    ok('русские ошибки и коды (bad_request / unsupported_format / '
        'geometry_error / file_not_found)');
  }

  // ===== 7. Производительность: полный путь по DXF — секунды (N-3) =====
  {
    final sw = Stopwatch()..start();
    final res = runPipeline({
      'fileName': 'quadroring.dxf',
      'file_base64': b64Of(fixture('quadroring.dxf')),
      'stages': ['all'],
    });
    sw.stop();
    expect(sw.elapsedMilliseconds < 30000,
        'N-3: полный путь укладывается в 30 с (факт: '
        '${sw.elapsedMilliseconds} мс)');
    expect(res.metrics['totalMs'] is int, 'метрики: totalMs присутствует');
    ok('полный путь за ${sw.elapsedMilliseconds} мс');
  }

  print('ALL PASS: pipeline_test');
}
