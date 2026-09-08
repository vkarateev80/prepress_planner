/// Экран «Экономика/ТЭО»: каталог, расчёт, сравнение, чувствительность.
///
/// Расчёт ТЭО — тривиальная арифметика над готовым MaterialResult: считается
/// синхронно, без изолята (в widget-test с runAsync реальный изолят не
/// успевает завершиться и расчёт «зависает»).
library;

import 'package:flutter/material.dart';
import 'package:prepress_core/prepress_core.dart';

import '../materials/material_library.dart';
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
  final MaterialLibrary? materials;
  const TeoScreen(
      {super.key,
      required this.project,
      required this.onChange,
      this.materials});

  @override
  State<TeoScreen> createState() => _TeoScreenState();
}

class _TeoScreenState extends State<TeoScreen> {
  final List<Machine> _machines = PriceCatalog.defaults().machines;
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

  /// Полный список материалов: каталог-пример + пользовательские.
  List<AssortmentItem> get _materials =>
      widget.materials?.all ?? PriceCatalog.defaults().assortment;

  /// Индекс выбранного материала (по [MaterialLibrary.selectedId]).
  int _materialIndex() {
    final id = widget.materials?.selectedId;
    if (id != null) {
      final i = _materials.indexWhere((a) => a.id == id);
      if (i >= 0) return i;
    }
    return 0;
  }

  bool _isCustomSelected() {
    final id = widget.materials?.selectedId;
    if (id == null) return false;
    return widget.materials?.customs.any((a) => a.id == id) ?? false;
  }

  @override
  void initState() {
    super.initState();
    widget.materials?.addListener(_onLibraryChanged);
  }

  @override
  void dispose() {
    widget.materials?.removeListener(_onLibraryChanged);
    _setupCtrl.dispose();
    _shiftHoursCtrl.dispose();
    _shiftsPerDayCtrl.dispose();
    _shiftCostCtrl.dispose();
    super.dispose();
  }

  void _onLibraryChanged() {
    if (!mounted) return;
    setState(() {
      final idx = _materialIndex();
      if (idx >= 0 && idx < _materials.length) {
        _priceM2 = _materials[idx].pricePerM2;
      }
    });
  }

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
          message: 'Материал и его цена за м² (каталог-пример + ваши материалы).',
          child: DropdownButtonFormField<int>(
            initialValue: _materialIndex(),
            isExpanded: true,
            decoration: const InputDecoration(
                labelText: 'Сортамент',
                border: OutlineInputBorder(),
                isDense: true),
            items: [
              for (var i = 0; i < _materials.length; i++)
                DropdownMenuItem(
                    value: i,
                    child: Text(
                        '${_materials[i].name} — ${_materials[i].pricePerM2.toStringAsFixed(0)} ₽/м²'
                        '${(widget.materials?.customs.any((a) => a.id == _materials[i].id) ?? false) ? ' · свой' : ''}')),
            ],
            onChanged: (v) {
              final m = _materials[v!];
              setState(() => _priceM2 = m.pricePerM2);
              widget.materials?.select(m.id);
            },
          ),
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            OutlinedButton.icon(
                onPressed: _showAddMaterial,
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Добавить материал')),
            if (_isCustomSelected())
              TextButton.icon(
                  onPressed: _confirmRemoveMaterial,
                  icon: const Icon(Icons.delete_outline, size: 18),
                  label: const Text('Удалить материал')),
            if (widget.materials?.error != null)
              Flexible(
                  child: Text(widget.materials!.error!,
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                          fontSize: 12))),
          ],
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
              for (var i = 0; i < _machines.length; i++)
                DropdownMenuItem(
                    value: i,
                    child: Text(
                        '${_machines[i].name} — ${_machines[i].ratePerHour.toStringAsFixed(0)} ₽/ч'))
            ],
            onChanged: (v) => setState(() {
              machineIndex = v!;
              _rate = _machines[v].ratePerHour;
              _setupMaterialM = _machines[v].setupMaterialMeters;
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
        _materials[_materialIndex()],
        _machineWithRate(_machines[machineIndex], _rate),
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
          name: _materials[_materialIndex()].name,
          pricePerM2: _priceM2);
      final result = _computeTeoDirect(
        calc,
        sensMaterial,
        _machineWithRate(_machines[machineIndex], _rate,
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

  void _toast(String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(message),
      duration: const Duration(seconds: 3),
    ));
  }

  /// Диалог «Новый материал»: название (спецификация), цена ₽/м²,
  /// минимальный заказ м² (необязательно).
  Future<void> _showAddMaterial() async {
    final lib = widget.materials;
    if (lib == null) {
      _toast('Каталог материалов недоступен.');
      return;
    }
    final nameCtrl = TextEditingController();
    final priceCtrl = TextEditingController();
    final minCtrl = TextEditingController();
    String? err;
    final created = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlg) => AlertDialog(
          title: const Text('Новый материал'),
          content: SizedBox(
            width: 400,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: nameCtrl,
                    autofocus: true,
                    decoration: const InputDecoration(
                        labelText: 'Название / спецификация',
                        hintText: 'Например: Плёнка ПЭТ 50 мкм',
                        border: OutlineInputBorder(),
                        isDense: true),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: priceCtrl,
                    keyboardType: const TextInputType.numberWithOptions(
                        decimal: true),
                    decoration: const InputDecoration(
                        labelText: 'Цена, ₽/м²',
                        border: OutlineInputBorder(),
                        isDense: true),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: minCtrl,
                    keyboardType: const TextInputType.numberWithOptions(
                        decimal: true),
                    decoration: const InputDecoration(
                        labelText: 'Мин. заказ, м² (необязательно)',
                        border: OutlineInputBorder(),
                        isDense: true),
                  ),
                  if (err != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(err!,
                          style: TextStyle(
                              color: Theme.of(ctx).colorScheme.error,
                              fontSize: 12)),
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Отмена')),
            FilledButton(
                onPressed: () async {
                  final price = double.tryParse(
                      priceCtrl.text.trim().replaceAll(',', '.'));
                  if (nameCtrl.text.trim().isEmpty ||
                      price == null ||
                      price <= 0) {
                    setDlg(() => err = 'Укажите название и цену больше 0.');
                    return;
                  }
                  final min = double.tryParse(
                      minCtrl.text.trim().replaceAll(',', '.'));
                  final okSave = await lib.add(
                    name: nameCtrl.text.trim(),
                    pricePerM2: price,
                    minOrderM2: min,
                  );
                  if (ctx.mounted) Navigator.pop(ctx, okSave);
                },
                child: const Text('Создать')),
          ],
        ),
      ),
    );
    if (created == true && mounted) {
      _toast('Материал добавлен и уже в списке «Сортамент».');
    }
  }

  /// Подтверждение удаления выбранного пользовательского материала.
  Future<void> _confirmRemoveMaterial() async {
    final lib = widget.materials;
    final id = lib?.selectedId;
    if (lib == null || id == null) return;
    final m = lib.resolve(id);
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Удалить материал?'),
        content: Text(
            '«${m.name}» будет удалён из вашего каталога. Примеры из встроенного каталога не удаляются.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Отмена')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: FilledButton.styleFrom(
                  backgroundColor: Theme.of(ctx).colorScheme.error),
              child: const Text('Удалить')),
        ],
      ),
    );
    if (yes == true) {
      await lib.remove(id);
      if (mounted) _toast('Материал удалён.');
    }
  }
}
