// Тест inflate (RFC 1951) на эталонах Python zlib (wbits=-15).
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../tool/test_utils.dart';
import '../lib/src/parser/inflate.dart';

void main() {
  final file = File('test/golden/deflate_cases.json');
  expect(file.existsSync(), 'deflate_cases.json существует');
  final data = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
  for (final entry in data.entries) {
    final name = entry.key;
    final raw = base64Decode((entry.value as Map<String, dynamic>)['raw_b64'] as String);
    final expected = base64Decode((entry.value as Map<String, dynamic>)['out_b64'] as String);
    Uint8List out;
    var mode = 'inflate';
    try {
      out = inflate(Uint8List.fromList(raw));
    } catch (_) {
      out = inflateZlib(Uint8List.fromList(raw));
      mode = 'inflateZlib';
    }
    expectEq(out.length, expected.length, '$name: длина ($mode)');
    var same = true;
    for (var i = 0; i < expected.length; i++) {
      if (out[i] != expected[i]) {
        same = false;
        break;
      }
    }
    expect(same, '$name: содержимое совпадает ($mode)');
    ok('inflate: $name ($mode)');
  }
  // ignore: avoid_print
  print('Все тесты inflate пройдены.');
}
