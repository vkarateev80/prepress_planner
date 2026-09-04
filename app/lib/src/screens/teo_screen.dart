/// Экран «Экономика/ТЭО»: каталог, расчёт, сравнение, чувствительность.
///
/// Расчёт ТЭО — тривиальная арифметика над готовым MaterialResult: считается
/// синхронно, без изолята (в widget-test с runAsync реальный изолят не
/// успевает завершиться и расчёт «зависает»).
library;

import 'package:flutter/material.dart';
import 'package:prepress_core/prepress_core.dart';

import '../projects/project.dart';

/// Синхронный расчёт ТЭО (мгновенно — только арифметика).
TeoResult _computeTeoDirect(
    MaterialResult calc,
    AssortmentItem material,
    Machine machine,
    double toolingCost,
    double markupPct,
    double materialSetupM,
    double hoursPerShift,
    int shiftsPerDay,
    double shiftCostPerShift) {
  final shape = shapeFromPreset('rect', calc.labelW, calc.labelH);
  final cons = computeConsumption(calc, shape);
  return computeTeo(
      calc,
      cons,
      TeoInput(
          material: material,
          machine: machine,
          workTime: WorkTime(
              hoursPerShift: hoursPerShift, shiftsPerDay: shiftsPerDay),
          toolingCost: toolingCost,
          markupPct: markupPct,
          setupMaterialMeters: materialSetupM,
          shiftCostPerShift: shiftCostPerShift));
}

class TeoScreen extends StatefulWidget {
  final Project? project;
  final ValueChanged<Project> onChange;
  const TeoScreen({super.key, required this.project, required this.onChange});

  @override
  State<TeoScreen> createState() => _TeoScreenState();
}

class _TeoScreenState extends State<TeoScreen> {
  PriceCatalog catalog = PriceCatalog.defaults();
  int materialIndex = 0;
  int machineIndex = 0;
  double tooling = 0;
  double markup = 0;
  double _setupMaterialM = 0; // материал на приладку, погонные метры
  final _setupCtrl = TextEditingController();
  double _hoursPerShift = 8; // часов в смене (режим работы)
  int _shiftsPerDay = 1; // смен в сутки
  final _shiftHoursCtrl = TextEditingController(text: '8');
  final _shiftsPerDayCtrl = TextEditingController(text: '1');
  double _shiftCost = 0; // цена одной смены, ₽
  final _shiftCostCtrl = TextEditingController();
  double _priceM2 = 100;
  double _speed = 100;
  double _rate = 5000;
  bool _busy = false;

  TeoResult? teo;

  @override
  Widget build(BuildContext context) {
    final project = widget.project;
    if (project == null) {
      return const Center(
          child: Text('Создайте или откройте проект на вкладке «Проекты».'));
    }
    final calc = project.calc;
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Text('Каталог затрат',
            style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        Tooltip(
          message: 'Материал и его цена за м² (из каталога затрат).',
          child: DropdownButtonFormField<int>(
            initialValue: materialIndex,
            isExpanded: true,
            decoration: const InputDecoration(
                labelText: 'Сортамент',
                border: OutlineInputBorder(),
                isDense: true),
            items: [
              for (var i = 0; i < catalog.assortment.length; i++)
                DropdownMenuItem(
                    value: i,
                    child: Text(
                        '${catalog.assortment[i].name} — ${catalog.assortment[i].pricePerM2.toStringAsFixed(0)} ₽/м²'))
            ],
            onChanged: (v) => setState(() {
              materialIndex = v!;
              _priceM2 = catalog.assortment[v].pricePerM2;
            }),
          ),
        ),
        const SizedBox(height: 8),
        Tooltip(
          message: 'Печатная машина и её ставка, ₽/ч (из каталога затрат).',
          child: DropdownButtonFormField<int>(
            initialValue: machineIndex,
            isExpanded: true,
            decoration: const InputDecoration(
                labelText: 'Машина',
                border: OutlineInputBorder(),
                isDense: true),
            items: [
              for (var i = 0; i < catalog.machines.length; i++)
                DropdownMenuItem(
                    value: i,
                    child: Text(
                        '${catalog.machines[i].name} — ${catalog.machines[i].ratePerHour.toStringAsFixed(0)} ₽/ч'))
            ],
            onChanged: (v) => setState(() {
              machineIndex = v!;
              _rate = catalog.machines[v].ratePerHour;
              _setupMaterialM = catalog.machines[v].setupMaterialMeters;
              _setupCtrl.text = _setupMaterialM == 0
                  ? ''
                  : _setupMaterialM.toString();
            }),
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 12,
          runSpacing: 8,
          children: [
            Tooltip(
              message: 'Стоимость изготовления оснастки/формы на тираж, ₽.',
              child: SizedBox(
                width: 140,
                child: TextField(
                  decoration: const InputDecoration(
                      labelText: 'Оснастка, ₽',
                      border: OutlineInputBorder(),
                      isDense: true),
                  keyboardType: TextInputType.number,
                  onChanged: (v) => tooling = double.tryParse(v) ?? 0,
                ),
              ),
            ),
            Tooltip(
              message: 'Торговая наценка в процентах от себестоимости тиража.',
              child: SizedBox(
                width: 140,
                child: TextField(
                  decoration: const InputDecoration(
                      labelText: 'Наценка, %',
                      border: OutlineInputBorder(),
                      isDense: true),
                  keyboardType: TextInputType.number,
                  onChanged: (v) => markup = double.tryParse(v) ?? 0,
                ),
              ),
            ),
            Tooltip(
              message: 'Расход материала на приладку (переналадку), погонные '
                  'метры полотна. Метры прибавляются к длине полотна тиража и '
                  'увеличивают расход материала.',
              child: SizedBox(
                width: 170,
                child: TextField(
                  controller: _setupCtrl,
                  decoration: const InputDecoration(
                      labelText: 'Приладка: материал, м',
                      border: OutlineInputBorder(),
                      isDense: true),
                  keyboardType: TextInputType.number,
                  onChanged: (v) =>
                      _setupMaterialM = double.tryParse(v) ?? 0,
                ),
              ),
            ),
            Tooltip(
              message: 'Часов в рабочей смене (режим предприятия).',
              child: SizedBox(
                width: 120,
                child: TextField(
                  controller: _shiftHoursCtrl,
                  decoration: const InputDecoration(
                      labelText: 'Смена, ч',
                      border: OutlineInputBorder(),
                      isDense: true),
                  keyboardType: TextInputType.number,
                  onChanged: (v) =>
                      _hoursPerShift = double.tryParse(v) ?? 8,
                ),
              ),
            ),
            Tooltip(
              message: 'Число смен в сутки: доступная мощность суток = '
                  '«часов в смене» × «смен». Влияет на загрузку смены.',
              child: SizedBox(
                width: 120,
                child: TextField(
                  controller: _shiftsPerDayCtrl,
                  decoration: const InputDecoration(
                      labelText: 'Смен в сутки',
                      border: OutlineInputBorder(),
                      isDense: true),
                  keyboardType: TextInputType.number,
                  onChanged: (v) =>
                      _shiftsPerDay = int.tryParse(v) ?? 1,
                ),
              ),
            ),
            Tooltip(
              message: 'Стоимость одной рабочей смены, ₽. Учитывается за '
                  'каждую занятую смену (время работы и переналадки).',
              child: SizedBox(
                width: 140,
                child: TextField(
                  controller: _shiftCostCtrl,
                  decoration: const InputDecoration(
                      labelText: 'Цена смены, ₽',
                      border: OutlineInputBorder(),
                      isDense: true),
                  keyboardType: TextInputType.number,
                  onChanged: (v) => _shiftCost = double.tryParse(v) ?? 0,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        FilledButton.icon(
            onPressed: calc == null || _busy ? null : _computeTeo,
            icon: const Icon(Icons.calculate),
            label: const Text('Рассчитать ТЭО')),
        if (_busy) const LinearProgressIndicator(),
        if (teo != null && teo!.error == null) ...[
          const Divider(),
          Text('ТЭО варианта',
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          _teoGrid(teo!),
          const Divider(),
          Text('Чувствительность',
              style: Theme.of(context).textTheme.titleMedium),
          _slider('Цена материала, ₽/м²',
              'Цена материала для сценария чувствительности, ₽/м².', _priceM2,
              20, 500, (v) => setState(() => _priceM2 = v)),
          _slider('Ставка машины, ₽/ч',
              'Ставка машины для сценария чувствительности, ₽/ч.', _rate, 500,
              20000, (v) => setState(() => _rate = v)),
          _slider('Скорость, м/мин',
              'Скорость печати для сценария чувствительности, м/мин.', _speed,
              10, 300, (v) => setState(() => _speed = v)),
          FilledButton.tonal(
              onPressed: _busy ? null : _recomputeSensitivity,
              child: const Text('Пересчитать')),
          if (_sensitivity != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                  'Себестоимость 1000 шт: ${_sensitivity!.costPer1000.toStringAsFixed(2)} ₽',
                  style: Theme.of(context).textTheme.titleMedium),
            ),
        ] else if (teo != null)
          Text('Ошибка ТЭО: ${teo!.error}',
              style: const TextStyle(color: Colors.red)),
      ],
    );
  }

  TeoResult? _sensitivity;

  @override
  void dispose() {
    _setupCtrl.dispose();
    _shiftHoursCtrl.dispose();
    _shiftsPerDayCtrl.dispose();
    _shiftCostCtrl.dispose();
    super.dispose();
  }

  Widget _slider(String label, String tip, double value, double min,
      double max, ValueChanged<double> onChanged) {
    return Row(
      children: [
        SizedBox(
            width: 240,
            child: Tooltip(
                message: tip,
                child: Text('$label: ${value.toStringAsFixed(0)}'))),
        Expanded(
            child: Slider(
                value: value.clamp(min, max),
                min: min,
                max: max,
                onChanged: onChanged)),
      ],
    );
  }

  Widget _teoGrid(TeoResult t) {
    Widget cell(String label, String value) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: Theme.of(context).textTheme.bodySmall),
            Text(value, style: Theme.of(context).textTheme.titleMedium),
          ],
        );
    return Wrap(
      spacing: 24,
      runSpacing: 12,
      children: [
        cell('Маш. время, ч', t.runTimeHours.toStringAsFixed(4)),
        cell('С переналадкой, ч', t.totalTimeHours.toStringAsFixed(4)),
        cell('Занято смен', '${t.shiftsUsed}'),
        cell('Машина, ₽', t.machineCost.toStringAsFixed(2)),
        cell('Материал, ₽', t.materialCost.toStringAsFixed(2)),
        cell('Смена, ₽', t.shiftCost.toStringAsFixed(2)),
        cell('Оснастка, ₽', t.toolingCost.toStringAsFixed(2)),
        cell('Наценка, ₽', t.markupCost.toStringAsFixed(2)),
        cell('ИТОГО, ₽', t.totalCost.toStringAsFixed(2)),
        cell('Себестоимость 1000, ₽', t.costPer1000.toStringAsFixed(2)),
        cell('За этикетку, ₽', t.costPerLabel.toStringAsFixed(2)),
        cell('Загрузка смены, %', '${t.shiftLoadPct.toStringAsFixed(1)}'),
      ],
    );
  }

  Future<void> _computeTeo() async {
    final project = widget.project!;
    final calc = project.calc!;
    setState(() => _busy = true);
    try {
      final result = _computeTeoDirect(
        calc,
        catalog.assortment[materialIndex],
        _machineWithRate(catalog.machines[machineIndex], _rate),
        tooling,
        markup,
        _setupMaterialM,
        _hoursPerShift,
        _shiftsPerDay,
        _shiftCost,
      );
      if (mounted) setState(() => teo = result);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Machine _machineWithRate(Machine m, double rate, {double? speed}) =>
      Machine(
        id: m.id,
        name: m.name,
        ratePerHour: rate,
        speedMetersPerMin: speed ?? m.speedMetersPerMin,
        labelsPerHour: m.labelsPerHour,
        setupTimeHours: m.setupTimeHours,
      );

  Future<void> _recomputeSensitivity() async {
    final project = widget.project!;
    final calc = project.calc!;
    setState(() => _busy = true);
    try {
      final sensMaterial = AssortmentItem(
          id: 'sens',
          name: catalog.assortment[materialIndex].name,
          pricePerM2: _priceM2);
      final result = _computeTeoDirect(
        calc,
        sensMaterial,
        _machineWithRate(catalog.machines[machineIndex], _rate,
            speed: _speed),
        tooling,
        markup,
        _setupMaterialM,
        _hoursPerShift,
        _shiftsPerDay,
        _shiftCost,
      );
      if (mounted) setState(() => _sensitivity = result);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}
