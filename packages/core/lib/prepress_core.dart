/// «Препресс-Планер» — домен (чистый Dart).
///
/// Барель пакета. Экспорты модулей добавляются по мере готовности:
/// geom (01) ✓, parser (02), healer/optimizer (03–04), calculator (05),
/// manufacturability (06), economics (07), reports (08).
library;

export 'src/model/model.dart';
export 'src/geom/polygon2.dart';
export 'src/geom/geom_ops.dart';
export 'src/geom/geom_boolean.dart';
export 'src/parser/parser_exception.dart';
export 'src/parser/base_parser.dart';
export 'src/parser/dxf_parser.dart';
export 'src/parser/svg_parser.dart';
export 'src/parser/pdf_parser.dart';
export 'src/parser/ai_pdf_parser.dart';
export 'src/parser/parse_file.dart';
export 'src/healer/morphology.dart';
export 'src/optimizer/topology.dart';
export 'src/calculator/material.dart';
export 'src/calculator/shape.dart';
export 'src/calculator/consumption.dart';
export 'src/calculator/layout_optimizer.dart';
