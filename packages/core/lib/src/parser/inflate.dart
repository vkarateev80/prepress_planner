/// Распаковка DEFLATE (RFC 1951): stored, fixed Huffman, dynamic Huffman.
/// Только стандартная библиотека. Используется для потоков /FlateDecode PDF.
library;

import 'dart:typed_data';

class InflateException implements Exception {
  final String message;
  const InflateException(this.message);
  @override
  String toString() => 'InflateException: $message';
}

class _BitReader {
  final Uint8List data;
  int bytePos = 0;
  int bitPos = 0; // 0..7, следующий бит — младший из оставшихся

  _BitReader(this.data);

  int readBits(int n) {
    var v = 0;
    for (var i = 0; i < n; i++) {
      if (bytePos >= data.length) {
        throw const InflateException('неожиданный конец потока');
      }
      final bit = (data[bytePos] >> bitPos) & 1;
      v |= bit << i;
      bitPos++;
      if (bitPos == 8) {
        bitPos = 0;
        bytePos++;
      }
    }
    return v;
  }

  void alignByte() {
    if (bitPos != 0) {
      bitPos = 0;
      bytePos++;
    }
  }
}

class _Huffman {
  final List<int> lengths;
  final List<int> symbols;
  final List<int> _count;
  final List<int> _sym;

  _Huffman(this.lengths, this.symbols, this._count, this._sym);

  /// Декодирование канонического кода: биты младшие-first, код возрастает.
  int decode(_BitReader br) {
    var code = 0;
    var first = 0;
    var index = 0;
    for (var len = 1; len <= 15; len++) {
      code |= br.readBits(1);
      final count = _count[len];
      if (count > 0 && code - first < count) {
        return _sym[index + (code - first)];
      }
      index += count;
      first = (first + count) << 1;
      code <<= 1;
    }
    throw const InflateException('битый Huffman-код');
  }

  static _Huffman fromLengths(List<int> lens) {
    // Канонические коды (deflate): биты младшие-first, код возрастает.
    final count = List<int>.filled(16, 0);
    for (final l in lens) {
      if (l > 0 && l < 16) count[l]++;
    }
    var code = 0;
    final nextCode = List<int>.filled(16, 0);
    for (var bits = 1; bits < 16; bits++) {
      code = (code + count[bits - 1]) << 1;
      nextCode[bits] = code;
    }
    final symbols = <int>[];
    final outLens = <int>[];
    for (var i = 0; i < lens.length; i++) {
      final l = lens[i];
      if (l == 0 || l >= 16) continue;
      symbols.add(i);
      outLens.add(l);
    }
    // Сортировка по длине кода (декадер идёт по возрастанию длины).
    final order = List<int>.generate(symbols.length, (i) => i);
    order.sort((a, b) {
      final c = outLens[a].compareTo(outLens[b]);
      return c != 0 ? c : symbols[a].compareTo(symbols[b]);
    });
    final sortedSym = order.map((i) => symbols[i]).toList();
    final sortedLens = order.map((i) => outLens[i]).toList();
    // Индексы начала каждой длины в отсортированном списке.
    final starts = List<int>.filled(16, 0);
    var idx = 0;
    for (var len = 1; len <= 15; len++) {
      starts[len] = idx;
      while (idx < sortedLens.length && sortedLens[idx] == len) {
        idx++;
      }
    }
    return _Huffman(sortedLens, sortedSym, count, sortedSym);
  }
}

/// Фиксированные таблицы Huffman (RFC 1951 §3.2.6).
List<int> _fixedLitLengths() {
  final lens = List<int>.filled(288, 8);
  for (var i = 144; i < 256; i++) {
    lens[i] = 9;
  }
  for (var i = 256; i < 280; i++) {
    lens[i] = 7;
  }
  for (var i = 280; i < 288; i++) {
    lens[i] = 8;
  }
  return lens;
}

List<int> _fixedDistLengths() => List<int>.filled(30, 5);

const List<int> _lenBase = [
  3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67,
  83, 99, 115, 131, 163, 195, 227, 258
];
const List<int> _lenExtra = [
  0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5,
  5, 5, 5, 0
];
const List<int> _distBase = [
  1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513,
  769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577
];
const List<int> _distExtra = [
  0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10,
  11, 11, 12, 12, 13, 13
];

/// Inflate c zlib-обёрткой (заголовок CMF/FLG, опциональный FDICT).
/// Некоторые PDF-производители оборачивают FlateDecode в zlib вопреки спецe.
Uint8List inflateZlib(Uint8List data) {
  if (data.length < 6) {
    throw const InflateException('zlib: слишком короткий поток');
  }
  final cmf = data[0];
  final flg = data[1];
  if ((cmf & 0x0F) != 8) {
    throw const InflateException('zlib: неверный CMF');
  }
  if ((cmf * 256 + flg) % 31 != 0) {
    throw const InflateException('zlib: битый заголовок');
  }
  var off = 2;
  if ((flg & 0x20) != 0) {
    off += 4; // FDICT
    if (off + 4 > data.length) {
      throw const InflateException('zlib: битый FDICT');
    }
  }
  return inflate(Uint8List.sublistView(data, off));
}

/// Распаковка raw DEFLATE (без zlib-обёртки).
Uint8List inflate(Uint8List data) {
  final br = _BitReader(data);
  final outBytes = <int>[];

  void emitByte(int b) => outBytes.add(b & 0xFF);

  final fixedLit = _Huffman.fromLengths(_fixedLitLengths());
  final fixedDist = _Huffman.fromLengths(_fixedDistLengths());
  var litTree = fixedLit;
  var distTree = fixedDist;

  while (true) {
    final bfinal = br.readBits(1);
    final btype = br.readBits(2);
    if (btype == 0) {
      // Stored.
      br.alignByte();
      final len = br.readBits(16);
      final nlen = br.readBits(16);
      if ((len ^ 0xFFFF) != nlen) {
        throw const InflateException('stored: битый NLEN');
      }
      for (var i = 0; i < len; i++) {
        if (br.bytePos >= data.length) {
          throw const InflateException('stored: неожиданный конец');
        }
        emitByte(data[br.bytePos++]);
      }
    } else if (btype == 2) {
      // Dynamic: коды длин.
      final hlit = br.readBits(5) + 257;
      final hdist = br.readBits(5) + 1;
      final hclen = br.readBits(4) + 4;
      const order = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15];
      final clLens = List<int>.filled(19, 0);
      for (var i = 0; i < hclen; i++) {
        clLens[order[i]] = br.readBits(3);
      }
      final clTree = _Huffman.fromLengths(clLens);
      final allLens = <int>[];
      while (allLens.length < hlit + hdist) {
        final sym = clTree.decode(br);
        if (sym < 16) {
          allLens.add(sym);
        } else if (sym == 16) {
          if (allLens.isEmpty) throw const InflateException('динамический: 16 без базы');
          final prev = allLens.last;
          final rep = 3 + br.readBits(2);
          for (var r = 0; r < rep; r++) {
            allLens.add(prev);
          }
        } else if (sym == 17) {
          final rep = 3 + br.readBits(3);
          for (var r = 0; r < rep; r++) {
            allLens.add(0);
          }
        } else {
          final rep = 11 + br.readBits(7);
          for (var r = 0; r < rep; r++) {
            allLens.add(0);
          }
        }
        if (allLens.length > hlit + hdist) {
          throw const InflateException('динамический: переполнение длин');
        }
      }
      final litLens = allLens.sublist(0, hlit);
      final distLens = allLens.sublist(hlit);
      litTree = _Huffman.fromLengths(litLens);
      distTree = _Huffman.fromLengths(distLens);
    } else if (btype == 1) {
      // Fixed Huffman: деревья фиксированы независимо от предыдущих блоков.
      litTree = fixedLit;
      distTree = fixedDist;
    } else {
      throw const InflateException('зарезервированный тип блока');
    }
    // Символы блока.
    while (true) {
      final sym = litTree.decode(br);
      if (sym < 256) {
        emitByte(sym);
      } else if (sym == 256) {
        break;
      } else {
        final li = sym - 257;
        if (li >= _lenBase.length) throw const InflateException('битая длина');
        var length = _lenBase[li];
        final extra = _lenExtra[li];
        if (extra > 0) length += br.readBits(extra);
        final dsym = distTree.decode(br);
        if (dsym >= _distBase.length) throw const InflateException('битая дистанция');
        var dist = _distBase[dsym];
        final dextra = _distExtra[dsym];
        if (dextra > 0) dist += br.readBits(dextra);
        final start = outBytes.length - dist;
        if (start < 0) throw const InflateException('дистанция больше вывода');
        // Перекрывающиеся копии читаем из растущего вывода (как LZ77).
        for (var k = 0; k < length; k++) {
          emitByte(outBytes[start + k]);
        }
      }
    }
    if (bfinal == 1) break;
  }
  return Uint8List.fromList(outBytes);
}
