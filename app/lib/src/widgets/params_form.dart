/// Форма параметров раскроя (LayoutParams).
library;

import 'package:flutter/material.dart';
import 'package:prepress_core/prepress_core.dart';

class ParamsForm extends StatefulWidget {
  final LayoutParams initial;
  final ValueChanged<LayoutParams> onChanged;
  const ParamsForm(
      {super.key, required this.initial, required this.onChanged});

  @override
  State<ParamsForm> createState() => _ParamsFormState();
}

class _ParamsFormState extends State<ParamsForm> {
  late final controllers = <String, TextEditingController>{
    'labelW': TextEditingController(text: _fmt(widget.initial.labelW)),
    'labelH': TextEditingController(text: _fmt(widget.initial.labelH)),
    'gapX': TextEditingController(text: _fmt(widget.initial.gapX)),
    'gapY': TextEditingController(text: _fmt(widget.initial.gapY)),
    'zTeeth': TextEditingController(text: '${widget.initial.zTeeth}'),
    'cp': TextEditingController(text: _fmt(widget.initial.cp)),
    'cylWidth': TextEditingController(text: _fmt(widget.initial.cylWidth)),
    'webWidth': TextEditingController(text: _fmt(widget.initial.webWidth)),
    'undercut': TextEditingController(text: _fmt(widget.initial.undercut)),
    'minGap': TextEditingController(text: _fmt(widget.initial.minGap)),
    'count': TextEditingController(text: '${widget.initial.count}'),
    'length': TextEditingController(text: _fmt(widget.initial.length)),
  };
  late String mode = widget.initial.mode;

  static String _fmt(double v) =>
      v == v.roundToDouble() ? '${v.toInt()}' : '$v';

  double _num(String key, double fallback) =>
      double.tryParse(controllers[key]!.text.trim()) ?? fallback;

  int _int(String key, int fallback) =>
      int.tryParse(controllers[key]!.text.trim()) ?? fallback;

  LayoutParams get params => LayoutParams(
        labelW: _num('labelW', 50),
        labelH: _num('labelH', 30),
        gapX: _num('gapX', 3),
        gapY: _num('gapY', 3),
        zTeeth: _int('zTeeth', 96),
        cp: _num('cp', 3.175),
        cylWidth: _num('cylWidth', 300),
        webWidth: _num('webWidth', 300),
        undercut: _num('undercut', 0.48),
        minGap: _num('minGap', 3),
        mode: mode,
        count: _int('count', 5000),
        length: _num('length', 10000),
      );

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 12,
            runSpacing: 8,
            children: [
              _field('Этикетка W, мм', 'labelW'),
              _field('Этикетка H, мм', 'labelH'),
              _field('Зазор X, мм', 'gapX'),
              _field('Зазор Y, мм', 'gapY'),
            ],
          ),
          Wrap(
            spacing: 12,
            runSpacing: 8,
            children: [
              _field('Зубья Z', 'zTeeth', width: 90),
              _field('Шаг CP, мм', 'cp'),
              _field('Цилиндр, мм', 'cylWidth'),
              _field('Полотно, мм', 'webWidth'),
            ],
          ),
          Wrap(
            spacing: 12,
            runSpacing: 8,
            children: [
              _field('Подрез, мм', 'undercut'),
              _field('Мин. зазор, мм', 'minGap'),
              _field('Кол-во N', 'count', width: 110),
              _field('Длина L, мм', 'length', width: 110),
            ],
          ),
          Row(
            children: [
              const Text('Режим: '),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(
                      value: 'count', label: Text('по количеству')),
                  ButtonSegment(value: 'length', label: Text('по длине')),
                ],
                selected: {mode},
                onSelectionChanged: (s) => setState(() => mode = s.first),
              ),
              const Spacer(),
              FilledButton(
                  onPressed: () => widget.onChanged(params),
                  child: const Text('Рассчитать')),
            ],
          ),
        ],
      ),
    );
  }

  Widget _field(String label, String key, {double width = 100}) {
    return SizedBox(
      width: width,
      child: TextField(
        controller: controllers[key],
        decoration: InputDecoration(
            labelText: label,
            isDense: true,
            border: const OutlineInputBorder()),
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
      ),
    );
  }
}
