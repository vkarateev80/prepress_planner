// Генерация примеров входа/выхода API в `test/examples/`.
//
// Живые файлы примеров не хранятся руками: этот скрипт прогоняет воркер и
// записывает фактический JSON (и ответ, и метрики), поэтому README всегда
// описывает реальное поведение сервиса.
//
// Запуск (из services/domain-worker):  dart tool/make_examples.dart
library;

import 'dart:convert';
import 'dart:io';

import '../lib/domain_worker.dart';

const JsonEncoder pretty = JsonEncoder.withIndent('  ');

Directory get outDir =>
    Directory('${Directory.current.path}/test/examples');

String fixture(String name) => '${Directory.current.path}/../../fixtures/$name';

String b64(String name) => base64Encode(File(fixture(name)).readAsBytesSync());

Map<String, dynamic> roundTrip(Map<String, dynamic> request) {
  final result = runPipeline(request);
  return result.toJson(includeRawPaths: request['includeRawPaths'] != false);
}

void write(String name, Object value) {
  final f = File('${outDir.path}/$name');
  f.writeAsStringSync('${pretty.convert(value)}\n');
  stdout.writeln('записан ${f.path} (${f.lengthSync()} байт)');
}

void main() {
  if (!outDir.existsSync()) outDir.createSync(recursive: true);
  final withGeometry = File(fixture('quadroring.svg')).existsSync();

  // ===== 1. Эталонный сценарий без файла: только раскрой и ТЭО =====
  final minimalRequest = <String, dynamic>{
    'stages': ['calc', 'teo'],
    'name': 'Тираж 5000, 50×30',
    'params': {
      'labelW': 50,
      'labelH': 30,
      'gapX': 3,
      'gapY': 3,
      'zTeeth': 96,
      'cp': 3.175,
      'cylWidth': 300,
      'webWidth': 300,
      'mode': 'count',
      'count': 5000,
    },
    'teoInput': {'materialId': 'paper-sa-80', 'machineId': 'flexo-300'},
    'includeRawPaths': false,
    'includeErrors': true,
  };
  write('request_minimal.json', minimalRequest);
  write('response_minimal.json', roundTrip(minimalRequest));

  // ===== 2. Полная цепочка по файлу (байты base64, как пришлёт api) =====
  if (withGeometry) {
    final fullRequest = <String, dynamic>{
      'stages': ['all'],
      'name': 'quadroring (полный путь)',
      'fileName': 'quadroring.svg',
      'file_base64': b64('quadroring.svg'),
      'includeRawPaths': false,
      'includeErrors': false,
      'variantsLimit': 20,
      'teoInput': {
        'materialId': 'paper-sa-80',
        'machineId': 'flexo-300',
        'toolingCost': 0,
        'markupPct': 0,
        'setupMaterialMeters': 0,
        'shiftCostPerShift': 0,
        'hoursPerShift': 8,
        'shiftsPerDay': 1,
      },
    };
    write('request_full.json', fullRequest);
    write('response_full.json', roundTrip(fullRequest));
  } else {
    stderr.writeln('предупреждение: fixtures/quadroring.svg не найден — '
        'пример полной цепочки пропущен');
  }

  // ===== 3. Мини-пример ответа /healthz =====
  write('healthz.json', {
    'status': 'ok',
    'service': 'domain-worker',
    'version': kWorkerVersion,
    'schemaVersion': kProjectStateSchemaVersion,
    'core': 'packages/core (path-зависимость, чистый Dart)',
    'isolates': true,
    'availableStages': kStageOrder,
  });

  stdout.writeln('готово: примеры в ${outDir.path}');
}
