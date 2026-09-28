/// Компоновка отчёта ТЭО (русский, A4) в PDF через [PdfDocument].
///
/// Кириллица рисуется внедрённым TTF (arial.ttf / DejaVuSans.ttf). Байты
/// шрифта передаёт вызывающий: на desktop их находит io-фасад
/// (lib/io.dart, [fontPathForCyrillic]), на web — встроенный ассет.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'pdf_writer.dart';
import 'report_models.dart';

/// Транслитерация русских строк в латиницу (документированный fallback,
/// если внедрение TTF недоступно). Используется только вне основного пути.
String translitRus(String s) {
  const map = <String, String>{
    'а': 'a', 'б': 'b', 'в': 'v', 'г': 'g', 'д': 'd', 'е': 'e', 'ё': 'e',
    'ж': 'zh', 'з': 'z', 'и': 'i', 'й': 'j', 'к': 'k', 'л': 'l', 'м': 'm',
    'н': 'n', 'о': 'o', 'п': 'p', 'р': 'r', 'с': 's', 'т': 't', 'у': 'u',
    'ф': 'f', 'х': 'h', 'ц': 'c', 'ч': 'ch', 'ш': 'sh', 'щ': 'sch',
    'ъ': '', 'ы': 'y', 'ь': '', 'э': 'e', 'ю': 'yu', 'я': 'ya',
  };
  final sb = StringBuffer();
  for (final r in s.runes) {
    final ch = String.fromCharCode(r);
    final low = ch.toLowerCase();
    final mapped = map[low];
    if (mapped == null) {
      sb.write(ch);
    } else {
      sb.write(ch == low ? mapped : _cap(mapped));
    }
  }
  return sb.toString();
}

String _cap(String s) =>
    s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

/// Имя формы по-русски.
String _shapeName(String kind) {
  switch (kind) {
    case 'rect':
      return 'прямоугольник';
    case 'roundRect':
      return 'прямоугольник со скруглением';
    case 'circle':
      return 'круг';
    case 'ellipse':
      return 'эллипс';
    case 'polygon':
      return 'многоугольник';
    default:
      return kind;
  }
}

String _d2(double v) => v.toStringAsFixed(2);
String _d1(double v) => v.toStringAsFixed(1);
String _pct(double v) => '${_d2(v)} %';
String _cur(double v, String c) => '${_d2(v)} $c';
String _mm(double v) => '${_d2(v)} мм';
String _hours(double v) => '${v} ч';

/// Материальная длина: мм → метры (3 знака).
String _m(double mm) => '${(mm / 1000.0).toStringAsFixed(3)} м';

/// Материальная площадь: мм² → м² (6 знаков — «на этикетку» малая).
String _m2(double mm2) => '${(mm2 / 1e6).toStringAsFixed(6)} м²';
String _date(DateTime d) {
  String p(int x) => x.toString().padLeft(2, '0');
  return '${p(d.day)}.${p(d.month)}.${d.year} ${p(d.hour)}:${p(d.minute)}';
}

/// Формат вывода: деньги — 2 знака; время — как хранится (4 знака);
/// площадь — до 5 значащих (raw double). Для страницы отчёта.
///
/// Генерация PDF-отчёта ТЭО (чистая функция: байты → байты).
/// [fontBytes] — TTF с кириллицей (см. [parseTtfFont]).
Uint8List buildTeoReportPdf(TeoReportData data, List<int> fontBytes) {
  final font = parseTtfFont(fontBytes, name: 'PrepressCyrillic');
  final doc = PdfDocument(font);
  _layout(doc, data);
  return doc.build();
}

// ============================================================
// Вёрстка
// ============================================================

class _Flow {
  final PdfDocument doc;
  final TeoReportData d;
  late PdfCanvas cv;
  double x = 45; // левая колонка (метки)
  double xVal = 250; // правая колонка (значения)
  double right = 552; // правый край контента
  double y = 48; // базовая линия текущей строки от верха
  double bottomLimit = 806; // 842 − запас

  _Flow(this.doc, this.d) {
    cv = doc.newPage();
  }

  void _ensure(double h) {
    if (y + h > bottomLimit) {
      cv = doc.newPage();
      y = 48;
    }
  }

  void title(String t, double size, {double lead = 20}) {
    _ensure(lead);
    final w = doc.font.widthPt(t, size);
    cv.text(t, x: (doc.pageWidth - w) / 2, yTop: y, size: size);
    y += lead;
  }

  void subtitle(String t, double size, {double lead = 14}) {
    _ensure(lead);
    final w = doc.font.widthPt(t, size);
    cv.text(t, x: (doc.pageWidth - w) / 2, yTop: y, size: size);
    y += lead;
  }

  void header(String t, {double size = 11, double lead = 16}) {
    _ensure(lead);
    cv.text(t, x: x, yTop: y, size: size);
    y += 2;
    cv.line(x, y + 3, right, y + 3, lineWidth: 0.7);
    y += lead - 2;
  }

  void row(String label, String value,
      {double size = 8.5, double lead = 11.5}) {
    _ensure(lead);
    cv.text(label, x: x, yTop: y, size: size);
    if (value.isNotEmpty) {
      cv.text(value, x: xVal, yTop: y, size: size);
    }
    y += lead;
  }

  void note(String t, {double size = 8, double lead = 10.5}) {
    _ensure(lead);
    cv.text(t, x: xVal, yTop: y, size: size);
    y += lead;
  }

  void gap(double h) {
    y += h;
  }
}

void _layout(PdfDocument doc, TeoReportData d) {
  final c = d.calc;
  final t = d.teo;
  final f = _Flow(doc, d);

  // ---------- Шапка ----------
  f.title('ТЭО РАСЧЁТА РАСКРОЯ', 14);
  f.title('Препресс-Планер — технико-экономическое обоснование', 9,
      lead: 13);
  f.row('Проект:', d.projectName, size: 9.5, lead: 13);
  f.row('Файл задания:', d.inputFile, size: 9.5, lead: 13);
  f.row('Дата:', '${_date(d.date)}  ·  смена ${_d1(d.workTime.hoursPerShift)} ч '
      '× ${d.workTime.shiftsPerDay}', size: 9.5, lead: 13);
  f.gap(6);

  // ---------- 1. Входные параметры ----------
  f.header('1. ВХОДНЫЕ ПАРАМЕТРЫ');
  f.row('Этикетка (W × H)', '${_mm(c.labelW)} × ${_mm(c.labelH)}');
  f.row('Форма',
      '${_shapeName(d.shape.kind)}, S = ${_d2(d.shape.area)} мм², '
      'заполнение bbox ${_pct(d.shape.efficiency * 100)}');
  f.row('Зазор (запрошен)',
      'X = ${_mm(c.gapX)}, Y = ${_mm(c.gapYRequested)}');
  f.row('Зазор по Y (факт.)',
      '${_mm(c.gapYActual)} (сходимость шва раппорта)');
  f.row('Шестерня',
      'Z = ${d.params.zTeeth}, CP = ${d.params.cp} мм');
  f.row('Раппорт', '${_mm(c.rapport)} = Z × CP');
  f.row('Цилиндр / полотно',
      '${_mm(d.params.cylWidth)} / ${_mm(d.params.webWidth)}');
  final modeName = d.params.mode == 'length' ? 'по длине' : 'по количеству';
  f.row('Режим', '$modeName (заказ N = ${c.countRequested})');

  // ---------- 2. Расход ----------
  f.header('2. РАСХОД МАТЕРИАЛА');
  f.row('Раскладка', '${c.rows} рядов × ${c.cols} колонок');
  f.row('Этикеток за оборот', '${c.perRev}');
  f.row('Оборотов полотна', '${c.revs}');
  f.row('Этикеток (N)', '${c.count} шт (заказ ${c.countRequested})');
  f.row('Длина полотна', '${_m(c.length)}');
  f.row('Площадь полотна', '${_m2(c.areaMm2)}');
  f.row('Площадь этикеток (форма)',
      '${_m2(d.consumption.usedAreaMm2)}');
  f.row('Отходы', '${_pct(c.wastePct)} (${_m2(d.consumption.wasteMm2)})');
  f.row('Полотно на этикетку', '${_m2(c.perLabelArea)}');

  // ---------- 3. Производство ----------
  f.header('3. ПРОИЗВОДСТВО');
  f.row('Машина', d.machine.name);
  f.row('Ставка машино-часа', _cur(d.machine.ratePerHour, d.currency));
  final speed = d.machine.speedMetersPerMin;
  f.row('Скорость', speed != null && speed > 0
      ? '${_d2(speed)} м/мин'
      : '${d.machine.labelsPerHour} этикеток/ч');
  f.row('Переналадка на заказ', _hours(d.machine.setupTimeHours));
  f.row('Машинное время печати', '${_d4(t.runTimeHours)} ч');
  f.row('Всего времени (с переналадкой)', '${_d4(t.totalTimeHours)} ч');
  f.row('Стоимость машиночасов', _cur(t.machineCost, d.currency));
  f.row('Загрузка смены',
      '${_pct(t.shiftLoadPct)} (${_d1(d.workTime.hoursPerShift)} ч × '
      '${d.workTime.shiftsPerDay})');

  // ---------- 4. Экономика ----------
  f.header('4. ЭКОНОМИКА');
  f.row('Сортамент',
      '${d.material.name}; ${_cur(d.material.pricePerM2, d.currency)}/м²');
  f.row('Стоимость материала', _cur(t.materialCost, d.currency));
  f.row('Занято смен', '${t.shiftsUsed}');
  f.row('Стоимость смен', _cur(t.shiftCost, d.currency));
  f.row('Оснастка (на заказ)', _cur(t.toolingCost, d.currency));
  f.row('Наценка', _cur(t.markupCost, d.currency));
  f.row('ИТОГО', _cur(t.totalCost, d.currency));
  f.row('Себестоимость 1000 шт', _cur(t.costPer1000, d.currency));
  f.row('Себестоимость этикетки', _cur(t.costPerLabel, d.currency));

  // ---------- 5. Сравнение вариантов ----------
  f.header('5. СРАВНЕНИЕ ВАРИАНТОВ');
  _tableHeader(f);
  if (d.comparison.variants.isEmpty) {
    f.note('— варианты не рассчитаны —');
  } else {
    final shown = d.comparison.variants.length > 12
        ? d.comparison.variants.sublist(0, 12)
        : d.comparison.variants;
    for (var i = 0; i < shown.length; i++) {
      final (v, vt) = shown[i];
      final best = i == 0 ? ' *' : '';
      _tableRow(f, '${i + 1}$best', '${v.rows}×${v.cols}',
          v.rotated ? 'да' : '—', '${v.count}',
          _pct(v.wastePct), _cur(vt.costPer1000, d.currency));
    }
    if (d.comparison.variants.length > shown.length) {
      f.note('… и ещё ${d.comparison.variants.length - shown.length} '
          'вариантов (таблица ограничена 12 лучшими)');
    }
    final best = d.comparison.bestCostPer1000;
    final base = d.comparison.baseCostPer1000;
    if (base - best > 0.001) {
      f.gap(2);
      f.row('Лучший вариант', _cur(best, d.currency) +
          ' — экономия ${_cur(d.comparison.savingsPer1000, d.currency)} '
          'на 1000 шт (${_d2(d.comparison.savingsPct)} %) против базы '
          '${_cur(base, d.currency)}');
    } else {
      f.gap(2);
      f.row('Лучший вариант', _cur(best, d.currency) +
          ' (совпадает с базой без поворота)');
    }
  }

  // ---------- 6. Эскиз ----------
  f.gap(4);
  f.header('6. ЭСКИЗ (ГАБАРИТЫ ЭТИКЕТКИ)');
  _drawSketch(f, d);

  // Номер страницы внизу (на последнем холсте).
  final cv = f.cv;
  final n = doc.pageCount;
  cv.text('Препресс-Планер · стр. $n', x: 45,
      yTop: doc.pageHeight - 24, size: 7);
}

String _d4(double v) => v.toStringAsFixed(4);

void _tableHeader(_Flow f) {
  f._ensure(11);
  final cv = f.cv;
  cv.text('№', x: 45, yTop: f.y, size: 8);
  cv.text('Сетка', x: 95, yTop: f.y, size: 8);
  cv.text('Пов.', x: 160, yTop: f.y, size: 8);
  cv.text('N', x: 205, yTop: f.y, size: 8);
  cv.text('Отходы', x: 260, yTop: f.y, size: 8);
  cv.text('₽ / 1000', x: 340, yTop: f.y, size: 8);
  f.y += 10;
  cv.line(45, f.y + 2, f.right, f.y + 2, lineWidth: 0.4);
  // y текста = базовая линия (глифы выше на ~6 pt у size 8): первая строка
  // должна начинаться ниже линии с запасом, иначе линия режет её середину
  // (живой прогон: линия 609 vs baseline строки 611 → наезд).
  f.y += 11;
}

void _tableRow(_Flow f, String no, String grid, String rot, String n,
    String waste, String cost) {
  f._ensure(11);
  final cv = f.cv;
  cv.text(no, x: 45, yTop: f.y, size: 8);
  cv.text(grid, x: 95, yTop: f.y, size: 8);
  cv.text(rot, x: 160, yTop: f.y, size: 8);
  cv.text(n, x: 205, yTop: f.y, size: 8);
  cv.text(waste, x: 260, yTop: f.y, size: 8);
  cv.text(cost, x: 340, yTop: f.y, size: 8);
  f.y += 10.5;
}

void _drawSketch(_Flow f, TeoReportData d) {
  final doc = f.doc;
  final shape = d.shape;
  final w = shape.w <= 0 ? 1.0 : shape.w;
  final h = shape.h <= 0 ? 1.0 : shape.h;
  const boxW = 220.0;
  const boxH = 120.0;
  final scale = math.min(boxW / w, boxH / h);
  final bw = w * scale;
  final bh = h * scale;
  final bx = (doc.pageWidth - bw) / 2;
  // Если блок не помещается на текущей странице — начинаем новую
  // (запас под подпись и масштаб под боксом — до 46 pt).
  if (f.y + 8 + bh + 46 > f.bottomLimit) {
    f.cv = doc.newPage();
    f.y = 48;
  }
  final py0 = f.y + 8; // верх бокса на (возможно новой) странице
  final cv = f.cv;
  cv.rect(bx, py0, bw, bh, lineWidth: 1.0);
  final cap1 = 'Этикетка ${_mm(shape.w)} × ${_mm(shape.h)}';
  final cap1W = doc.font.widthPt(cap1, 8);
  // Подпись рисуем ВНУТРИ бокса только когда она реально влезает
  // (по ширине с запасом и по высоте); иначе — под боксом, чтобы
  // текст не наезжал на границы этикетки (узкие/высокие габариты).
  final inside = cap1W <= bw - 8 && bh >= 16;
  if (inside) {
    cv.text(cap1,
        x: (doc.pageWidth - cap1W) / 2,
        yTop: py0 + bh / 2 - 4, size: 8);
  } else {
    // Базовая линия на 8 pt ниже границы: глифы (cap-height ≈ 5.7 pt
    // у size 8) гарантированно не касаются линии бокса.
    cv.text(cap1,
        x: (doc.pageWidth - cap1W) / 2,
        yTop: py0 + bh + 8, size: 8);
  }
  final cap2 = 'увеличение ×${scale.toStringAsFixed(1)} '
      '(1:${(1 / scale).toStringAsFixed(2)})';
  cv.text(cap2,
      x: (doc.pageWidth - doc.font.widthPt(cap2, 7)) / 2,
      yTop: py0 + bh + (inside ? 12 : 22), size: 7);
  f.y = py0 + bh + (inside ? 30 : 40);
}
