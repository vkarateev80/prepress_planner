/// Низкоуровневый генератор XLSX: store-zip (метод 0, без сжатия) + XML.
///
/// ZIP собран вручную (только stdlib): локальные заголовки + центральный
/// каталог + EOCD. CRC32 — табличным методом (IEEE 802.3, полином
/// 0xEDB88320). XML использует inline-строки
/// (`<c t="inlineStr"><is><t>…</t></is></c>`), поэтому sharedStrings
/// не нужен.
library;

import 'dart:convert';
import 'dart:typed_data';

// ============================================================
// CRC32
// ============================================================

final Uint32List _crcTable = _makeCrcTable();

Uint32List _makeCrcTable() {
  final t = Uint32List(256);
  for (var n = 0; n < 256; n++) {
    var c = n;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? (0xEDB88320 ^ (c >>> 1)) : (c >>> 1);
    }
    t[n] = c & 0xFFFFFFFF;
  }
  return t;
}

int crc32(List<int> data) {
  var c = 0xFFFFFFFF;
  for (final b in data) {
    c = (_crcTable[(c ^ b) & 0xFF] ^ (c >>> 8)) & 0xFFFFFFFF;
  }
  return c ^ 0xFFFFFFFF;
}

// ============================================================
// ZIP (store)
// ============================================================

/// Элемент архива: имя (ASCII) + содержимое.
class ZipEntry {
  final String name;
  final Uint8List data;
  ZipEntry(this.name, this.data);
}

class _ZipWriter {
  final BytesBuilder _local = BytesBuilder();
  final List<(String, int, int, int)> _central = []; // имя, crc, size, offset

  void _u16(int v) {
    _local.addByte(v & 0xFF);
    _local.addByte((v >> 8) & 0xFF);
  }

  void _u32(int v) {
    _local.addByte(v & 0xFF);
    _local.addByte((v >> 8) & 0xFF);
    _local.addByte((v >> 16) & 0xFF);
    _local.addByte((v >> 24) & 0xFF);
  }

  // DOS-дата/время: фиксированная (2024-01-01 00:00:00).
  static const _dosDate = 0x4A21; // (44 << 9) | (1 << 5) | 1
  static const _dosTime = 0;

  void add(ZipEntry e) {
    final nameBytes = ascii.encode(e.name);
    final data = e.data;
    final offset = _local.length;
    final crc = crc32(data);
    // Локальный заголовок.
    _u32(0x04034B50);
    _u16(20); // version needed
    _u16(0); // flags
    _u16(0); // method: store
    _u16(_dosTime);
    _u16(_dosDate);
    _u32(crc);
    _u32(data.length);
    _u32(data.length);
    _u16(nameBytes.length);
    _u16(0); // extra len
    _local.add(nameBytes);
    _local.add(data);
    _central.add((e.name, crc, data.length, offset));
  }

  Uint8List finish() {
    final centralOffset = _local.length;
    final cd = BytesBuilder();
    for (final (name, crc, size, offset) in _central) {
      final nameBytes = ascii.encode(name);
      cd.addByte(0x50);
      cd.addByte(0x4B);
      cd.addByte(0x01);
      cd.addByte(0x02);
      _u16To(cd, 20); // version made by
      _u16To(cd, 20); // version needed
      _u16To(cd, 0); // flags
      _u16To(cd, 0); // method
      _u16To(cd, _dosTime);
      _u16To(cd, _dosDate);
      _u32To(cd, crc);
      _u32To(cd, size);
      _u32To(cd, size);
      _u16To(cd, nameBytes.length);
      _u16To(cd, 0); // extra
      _u16To(cd, 0); // comment
      _u16To(cd, 0); // disk
      _u16To(cd, 0); // internal attrs
      _u32To(cd, 0); // external attrs
      _u32To(cd, offset);
      cd.add(nameBytes);
    }
    final cdSize = cd.length;
    // EOCD.
    cd.addByte(0x50);
    cd.addByte(0x4B);
    cd.addByte(0x05);
    cd.addByte(0x06);
    _u16To(cd, 0); // disk
    _u16To(cd, 0); // cd start disk
    _u16To(cd, _central.length);
    _u16To(cd, _central.length);
    _u32To(cd, cdSize);
    _u32To(cd, centralOffset);
    _u16To(cd, 0); // comment len

    final out = BytesBuilder();
    out.add(_local.toBytes());
    out.add(cd.toBytes());
    return out.toBytes();
  }

  static void _u16To(BytesBuilder b, int v) {
    b.addByte(v & 0xFF);
    b.addByte((v >> 8) & 0xFF);
  }

  static void _u32To(BytesBuilder b, int v) {
    b.addByte(v & 0xFF);
    b.addByte((v >> 8) & 0xFF);
    b.addByte((v >> 16) & 0xFF);
    b.addByte((v >> 24) & 0xFF);
  }
}

/// Сборка store-zip из записей [entries].
Uint8List buildZip(List<ZipEntry> entries) {
  final w = _ZipWriter();
  for (final e in entries) {
    w.add(e);
  }
  return w.finish();
}

// ============================================================
// XML-хелперы для электронных таблиц
// ============================================================

String _xmlEscape(String s) {
  final sb = StringBuffer();
  for (final r in s.runes) {
    switch (r) {
      case 0x26: // &
        sb.write('&amp;');
      case 0x3C: // <
        sb.write('&lt;');
      case 0x3E: // >
        sb.write('&gt;');
      case 0x22: // "
        sb.write('&quot;');
      case 0x27: // '
        sb.write('&apos;');
      default:
        if (r < 0x20 && r != 0x09 && r != 0x0A && r != 0x0D) {
          continue; // XML 1.0 запрещает управляющие символы
        }
        sb.writeCharCode(r);
    }
  }
  return sb.toString();
}

/// Имя колонки A..Z, AA.. (1-based индекс).
String colName(int col) {
  var c = col;
  final sb = StringBuffer();
  while (c > 0) {
    final m = (c - 1) % 26;
    sb.writeCharCode(0x41 + m);
    c = (c - 1) ~/ 26;
  }
  return sb.toString().split('').reversed.join();
}

/// Ячейка с числом: `<c r="B2"><v>5040</v></c>`.
String cellNumber(int row, int col, Object value) {
  final v = value is double ? _numStr(value) : '$value';
  return '<c r="${colName(col)}$row"><v>$v</v></c>';
}

/// Ячейка со строкой (inline): `<c r="A1" t="inlineStr"><is><t>…</t></is></c>`.
String cellString(int row, int col, String value) {
  final s = _xmlEscape(value);
  return '<c r="${colName(col)}$row" t="inlineStr"><is><t>$s</t></is></c>';
}

/// Текст числа для ячейки: int — без точки; double — кратчайший десятичный
/// вид Dart ('26.18', '2032.0'), без экспоненты для типичных значений.
String _numStr(double v) => '$v';
