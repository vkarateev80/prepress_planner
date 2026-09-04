/// Форма параметров раскроя (LayoutParams).
///
/// Подпись каждого параметра вынесена над полем ввода и обрезается по ширине
/// колонки (TextOverflow.ellipsis), поэтому длинные подписи больше не
/// «вылезают» за границу своего поля на соседние. При наведении курсора на
/// параметр всплывает комментарий (Tooltip), поясняющий его смысл и формулу.
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            _param('Этикетка W, мм', 'labelW',
                'Ширина этикетки поперёк полотна, мм. Обычно берётся из файла '
                    'геометрии либо из задания.'),
            _param('Этикетка H, мм', 'labelH',
                'Высота этикетки вдоль движения полотна, мм.'),
            _param('Зазор X, мм', 'gapX',
                'Боковой зазор между колонками этикеток, мм. '
                    'Шаг колонки = W + зазор X.'),
            _param('Зазор Y, мм', 'gapY',
                'Желаемый продольный зазор между рядами, мм. Фактический шаг '
                    'ряда = раппорт ÷ число рядов, чтобы шов на цилиндре '
                    'сходился.'),
          ],
        ),
        const SizedBox(height: 4),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            _param('Зубья Z', 'zTeeth',
                'Число зубьев шестерни печатного цилиндра. Раппорт = Z × CP '
                    '(например, 96 × 3,175 = 304,8 мм).', width: 100),
            _param('Шаг CP, мм', 'cp',
                'Шаг зубьев шестерни, мм. Флексопечатный стандарт 1/8″ = '
                    '3,175 мм.'),
            _param('Цилиндр, мм', 'cylWidth',
                'Рабочая ширина печатного цилиндра, мм. Число колонок '
                    'ограничено min(цилиндр, полотно).'),
            _param('Полотно, мм', 'webWidth',
                'Ширина плёнки/полотна материала, мм. Задаёт площадь расхода '
                    'и процент отходов.'),
          ],
        ),
        const SizedBox(height: 4),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            _param('Подрез, мм', 'undercut',
                'Подрез цилиндра, мм: диаметр тела dCyl = делительный диаметр '
                    '− 2 × подрез (создаёт натяжение полотна).'),
            _param('Мин. зазор, мм', 'minGap',
                'Минимально допустимый зазор между этикетками, мм. '
                    'Используется при подборе рядов (сходимость шва).'),
            _param('Кол-во N', 'count',
                'Тираж в штуках (режим «по количеству»). Расчёт округляет N '
                    'до целого числа оборотов цилиндра.'),
            _param('Длина L, мм', 'length',
                'Длина полотна в мм (режим «по длине»). Число этикеток = '
                    'целые обороты × этикеток за оборот.'),
          ],
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 16,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            const Text('Режим расчёта:'),
            Tooltip(
              message: 'Как задан тираж: числом этикеток N или длиной '
                  'полотна L.',
              child: SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'count', label: Text('по количеству')),
                  ButtonSegment(value: 'length', label: Text('по длине')),
                ],
                selected: {mode},
                onSelectionChanged: (s) => setState(() => mode = s.first),
              ),
            ),
            Tooltip(
              message: 'Выполнить расчёт расхода материала по текущим '
                  'параметрам.',
              child: FilledButton(
                  onPressed: () => widget.onChanged(params),
                  child: const Text('Рассчитать')),
            ),
          ],
        ),
      ],
    );
  }

  /// Параметр раскроя: подпись над полем + всплывающий комментарий.
  Widget _param(String label, String key, String help, {double width = 128}) {
    return Tooltip(
      message: '$label — $help',
      waitDuration: const Duration(milliseconds: 350),
      child: SizedBox(
        width: width,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 4),
            TextField(
              controller: controllers[key],
              decoration: const InputDecoration(
                isDense: true,
                contentPadding:
                    EdgeInsets.symmetric(horizontal: 8, vertical: 10),
                border: OutlineInputBorder(),
              ),
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
            ),
          ],
        ),
      ),
    );
  }
}
