// Диагностика расхождения inflate на оригинальном потоке Corel.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../lib/src/parser/inflate.dart';

void main() {
  final m = jsonDecode(File('test/golden/obj8_orig.json').readAsStringSync())
      as Map<String, dynamic>;
  final raw = base64Decode(m['raw_b64'] as String);
  final expected = base64Decode(m['out_b64'] as String);
  // ignore: avoid_print
  print('raw ${raw.length} expected ${expected.length} head ${raw.sublist(0, 4).map((b) => b.toRadixString(16)).join(' ')}');
  Uint8List out;
  try {
    out = inflateZlib(Uint8List.fromList(raw));
  } catch (e) {
    // ignore: avoid_print
    print('inflateZlib FAILED: $e');
    final partial = debugPartial;
    if (partial != null) {
      var diff = -1;
      for (var i = 0; i < partial.length && i < expected.length; i++) {
        if (partial[i] != expected[i]) {
          diff = i;
          break;
        }
      }
      // ignore: avoid_print
      print('partial ${partial.length}; first diff at: $diff');
      if (diff >= 0) {
        final from = diff > 8 ? diff - 8 : 0;
        // ignore: avoid_print
        print('expected: ${expected.sublist(from, diff + 16).map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ')}');
        // ignore: avoid_print
        print('actual  : ${partial.sublist(from, diff + 16 > partial.length ? partial.length : diff + 16).map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ')}');
      }
    }
    return;
  }
  // ignore: avoid_print
  print('out ${out.length}');
  var diff = -1;
  for (var i = 0; i < out.length && i < expected.length; i++) {
    if (out[i] != expected[i]) {
      diff = i;
      break;
    }
  }
  // ignore: avoid_print
  print('first diff at: $diff (of ${out.length})');
  if (diff >= 0) {
    // ignore: avoid_print
    print('expected ctx: ${expected.sublist(diff > 4 ? diff - 4 : 0, diff + 8).map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ')}');
    // ignore: avoid_print
    print('actual   ctx: ${out.sublist(diff > 4 ? diff - 4 : 0, diff + 8).map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ')}');
  }
}
