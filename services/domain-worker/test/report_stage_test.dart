// Стадия отчётов (§12.8): PDF ТЭО / XLSX / DXF из состояния расчёта.
//
// Запуск:  dart test/report_stage_test.dart   (из services/domain-worker)
library;

import 'dart:convert';
import 'dart:io';

import '../lib/domain_worker.dart';
import '../tool/test_utils.dart';

/// Эталонный запрос PRD §10.2 (параметры без макета) + секция отчёта.
Map<String, dynamic> _request(Map<String, dynamic> report) => {
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
      'report': report,
    };

Map<String, dynamic> _report(PipelineResult result) {
  final rep = result.stageResults['report'];
  if (rep is! Map<String, dynamic>) {
    throw StateError('ОШИБКА ТЕСТА: stageResults.report отсутствует');
  }
  return rep;
}

/// Кириллица UTF-16BE в байтах PDF (как в tool/verify_reports.dart).
bool _hasCyrillicUtf16Be(List<int> bytes) {
  for (var i = 0; i + 1 < bytes.length; i += 2) {
    if (bytes[i] == 0x04 && bytes[i + 1] >= 0x10 && bytes[i + 1] <= 0x4F) {
      return true;
    }
  }
  return false;
}

void main() {
  // ===== 1. PDF: %PDF-, CID-шрифт, кириллица =====
  {
    final font =
        File('../../app/assets/fonts/DejaVuSans.ttf').readAsBytesSync();
    final result =
        runPipeline(_request({'format': 'pdf', 'fontBase64': base64Encode(font)}));
    final rep = _report(result);

    expectEq(rep['mime'], 'application/pdf', 'pdf: mime');
    expect((rep['name'] as String).endsWith('.pdf'), 'pdf: имя файла .pdf');
    final pdf = base64Decode(rep['contentBase64'] as String);
    final text = String.fromCharCodes(pdf);
    expect(text.startsWith('%PDF-'), 'pdf: сигнатура %PDF-');
    expect(text.contains('Type0'), 'pdf: CID-шрифт Type0 (кириллица)');
    expect(text.contains('Identity-H'), 'pdf: кодировка Identity-H');
    expect(text.contains('%%EOF'), 'pdf: завершён (%%EOF)');
    expect(_hasCyrillicUtf16Be(pdf), 'pdf: кириллица UTF-16BE в глифах');
    expect((rep['size'] as int) > 100000, 'pdf: содержательный размер');
    ok('PDF ТЭО: построен, CID-шрифт, кириллица');
  }

  // ===== 2. XLSX: ZIP-контейнер =====
  {
    final result = runPipeline(_request({'format': 'xlsx'}));
    final rep = _report(result);
    expectEq(rep['mime'],
        'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
        'xlsx: mime');
    final bytes = base64Decode(rep['contentBase64'] as String);
    expect(bytes.length > 5000, 'xlsx: размер > 5 КБ');
    expect(String.fromCharCodes(bytes.sublist(0, 2)) == 'PK',
        'xlsx: ZIP-сигнатура');
    ok('XLSX ТЭО: построен (ZIP)');
  }

  // ===== 3. DXF мастера: макет → лечение → DXF =====
  {
    final result = runPipeline({
      'stages': ['heal'],
      'name': 'Д',
      'rawPaths': [
        {
          'points': [
            [0, 0],
            [50, 0],
            [50, 30],
            [0, 30]
          ],
          'closed': true,
        },
      ],
      'report': {'format': 'dxf', 'paths': 'master'},
    });
    final rep = _report(result);
    expectEq(rep['mime'], 'application/dxf', 'dxf: mime');
    expect((rep['name'] as String).endsWith('-мастер.dxf'),
        'dxf: суффикс -мастер');
    final text = utf8.decode(base64Decode(rep['contentBase64'] as String));
    expect(text.contains('SECTION'), 'dxf: SECTION');
    expect(text.contains('LWPOLYLINE'), 'dxf: LWPOLYLINE');
    expect(text.trimRight().endsWith('EOF'), 'dxf: EOF');
    ok('DXF мастера: построен');
  }

  // ===== 4. Ошибки: формат и пустой массив =====
  {
    try {
      runPipeline(_request({'format': 'docx'}));
      throw StateError('ОШИБКА ТЕСТА: неверный формат не отклонён');
    } on WorkerError catch (e) {
      expectEq(e.code, 'bad_request', 'ошибочный формат → bad_request');
      expect(e.message.contains('pdf, xlsx или dxf'),
          'ошибочный формат: русское сообщение');
    }
    ok('отчёт: неверный формат отклонён');
  }
  {
    try {
      runPipeline({
        'stages': ['heal'],
        'rawPaths': [
          {
            'points': [
              [0, 0],
              [10, 0],
              [10, 10]
            ],
            'closed': true,
          },
        ],
        'report': {'format': 'dxf', 'paths': 'array'},
      });
      throw StateError('ОШИБКА ТЕСТА: пустой массив не отклонён');
    } on WorkerError catch (e) {
      expectEq(e.code, 'geometry_error', 'пустой массив → geometry_error');
      expect(e.message.contains('Массив не распознан'),
          'пустой массив: русское сообщение');
    }
    ok('отчёт: DXF массива без массива отклонён');
  }

  // ===== 5. Ошибки: нет расчёта для PDF =====
  {
    try {
      runPipeline({
        'stages': ['parse'],
        'rawPaths': [
          {
            'points': [
              [0, 0],
              [1, 1]
            ],
            'closed': true,
          },
        ],
        'report': {'format': 'pdf', 'fontBase64': 'AA=='},
      });
      throw StateError('ОШИБКА ТЕСТА: PDF без расчёта не отклонён');
    } on WorkerError catch (e) {
      expectEq(e.code, 'geometry_error', 'PDF без calc → geometry_error');
      expect(e.message.contains('Расчёт раскроя не выполнен'),
          'PDF без calc: русское сообщение');
    }
    ok('отчёт: PDF без стадии calc отклонён');
  }
}
