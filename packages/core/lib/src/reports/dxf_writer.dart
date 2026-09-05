/// Генератор текстового DXF R2000 (AC1015) из [CamPath]: List<CamPath> → .dxf.
///
/// Структура: HEADER ($ACADVER, $INSUNITS=4 — мм), TABLES (слои имён путей),
/// ENTITIES (LWPOLYLINE с кодом 90 = число вершин, 70 = флаг замкнутости,
/// 10/20 = координаты). Координаты округляются до 4 знаков; имена слоёв с
/// не-ASCII символами кодируются как \U+XXXX (семантика ezdxf/парсера).
library;

import '../model/cam_path.dart';

/// Не-ASCII символы имени слоя → \U+XXXX (по 4 hex-цифры на символ BMP).
String _encodeDxfName(String s) {
  final sb = StringBuffer();
  for (final r in s.runes) {
    if (r > 0x7F && r <= 0xFFFF) {
      sb.write('\\U+${r.toRadixString(16).toUpperCase().padLeft(4, '0')}');
    } else {
      sb.writeCharCode(r);
    }
  }
  return sb.toString();
}

String _num(double v) => v.toStringAsFixed(4);

/// Текст DXF-файла с путями [paths] (каждый — LWPOLYLINE на своём слое).
/// [version] — 'AC1015' (R2000); при других значениях заголовок меняется.
/// Чистая функция: файл на диск пишет io-фасад (lib/io.dart).
String buildDxfText(List<CamPath> paths, {String version = 'AC1015'}) {
  final sb = StringBuffer();
  void pair(int code, String value) {
    sb.write('$code\r\n$value\r\n');
  }

  // ---------- HEADER ----------
  pair(0, 'SECTION');
  pair(2, 'HEADER');
  pair(9, r'$ACADVER');
  pair(1, version);
  pair(9, r'$INSUNITS');
  pair(70, '4'); // миллиметры
  pair(0, 'ENDSEC');

  // ---------- TABLES: слои ----------
  final layers = <String>[];
  for (final p in paths) {
    final name = (p.layerName.isEmpty) ? '0' : p.layerName;
    if (!layers.contains(name)) layers.add(name);
  }
  if (layers.isEmpty) layers.add('0');
  pair(0, 'SECTION');
  pair(2, 'TABLES');
  pair(0, 'TABLE');
  pair(2, 'LAYER');
  pair(70, '${layers.length}');
  for (final l in layers) {
    pair(0, 'LAYER');
    pair(2, _encodeDxfName(l));
    pair(70, '0');
    pair(62, '7');
    pair(6, 'CONTINUOUS');
  }
  pair(0, 'ENDTAB');
  pair(0, 'ENDSEC');

  // ---------- ENTITIES ----------
  pair(0, 'SECTION');
  pair(2, 'ENTITIES');
  for (final p in paths) {
    if (p.points.length < 2) continue;
    final layer = (p.layerName.isEmpty) ? '0' : p.layerName;
    pair(0, 'LWPOLYLINE');
    pair(8, _encodeDxfName(layer));
    pair(90, '${p.points.length}');
    pair(70, p.isClosed ? '1' : '0');
    for (final v in p.points) {
      pair(10, _num(v.x));
      pair(20, _num(v.y));
    }
  }
  pair(0, 'ENDSEC');
  pair(0, 'EOF');

  return sb.toString();
}
