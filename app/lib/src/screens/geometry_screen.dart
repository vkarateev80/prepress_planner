/// Экран «Геометрия»: импорт, ошибки, лечение, массив/сетка.
///
/// Поток по требованию пользователя: распознать массив → найти отдельный
/// элемент (мастер) и закон расположения (ряды×колонки, шаг, зазоры) →
/// вылечить ТОЛЬКО мастер-элемент → размножить его по тому же закону на
/// отдельный слой ('ARRAY') → автоматически заполнить параметры раскроя.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:prepress_core/prepress_core.dart';

import '../../platform/env.dart';
import '../../platform/files.dart';
import '../../platform/isolates.dart';
import '../../platform/save_out.dart';
import '../converter/api_converter.dart';
import '../converter/converter_api.dart';
import '../converter/converter_server.dart';
import '../logs/app_log.dart';
import '../projects/project.dart';
import '../widgets/geometry_canvas.dart';

/// Максимальное время локального разбора/анализа файла (SVG/DXF/PDF), после
/// которого импорт прерывается с понятной ошибкой вместо «вечной загрузки».
const _fileTimeout = Duration(seconds: 90);

/// Тяжёлые операции домена: только топ-левел функции (замыкание, уходящее
/// в изолят, создаётся в собственной активации и не захватывает состояние
/// экрана — иначе VM делит контекст активации с setState-замыканием, и
/// отправка падает: «object is unsendable»). На desktop [heavy] выполняется
/// в изоляте (Isolate.run), на web — на главном потоке (изолятов в браузере
/// нет).

/// Выбранный пользователем файл импорта: имя (по нему определяется формат),
/// байты содержимого и строка для Project.inputFile (desktop — полный путь,
/// web — имя файла).
class _ImportFile {
  final String name;
  final Uint8List bytes;
  final String display;
  const _ImportFile({
    required this.name,
    required this.bytes,
    required this.display,
  });
}

/// Имя файла из полного пути (часть после последнего «/» или «\»).
String _pathBase(String path) {
  final parts = path.split(RegExp(r'[\\/]'));
  return parts.isEmpty ? path : parts.last;
}

/// Только разбор байтов файла (SVG/DXF/PDF/AI) — без анализа; анализ идёт
/// отдельным шагом, чтобы в статусе было видно происходящее.
Future<List<CamPath>> _parseBytesHeavy(String name, Uint8List bytes) =>
    heavy(() => parseBytes(bytes, name));

Future<List<CamPath>> _heavyHeal(List<CamPath> raw) =>
    heavy(() => healGeometry(raw, ManufacturingParams()));

Future<List<Issue>> _heavyAnalyze(List<CamPath> healed) => heavy(
    () => analyzeManufacturability(healed, ManufacturingParams()).issues);

Future<PatternResult> _heavyRecognize(List<CamPath> healed) =>
    heavy(() => PatternRecognizer().analyze(healed));

Future<List<CamPath>> _heavyGrid(List<CamPath> master,
        {required int cols,
        required int rows,
        required double stepX,
        required double stepY}) =>
    heavy(() => generateArrayGrid(master,
        cols: cols, rows: rows, stepX: stepX, stepY: stepY));

Future<List<CamPath>> _heavyFix(List<CamPath> raw, Issue issue) =>
    heavy(() => applyIssueFix(raw, issue, ManufacturingParams()));

/// Выполнение [future] с общим таймаутом локальных операций (вместо
/// «вечной загрузки» — понятная ошибка за [_fileTimeout]).
Future<T> _timed<T>(Future<T> future, String what) => future.timeout(
      _fileTimeout,
      onTimeout: () => throw TimeoutException(
          '$what заняло больше ${_fileTimeout.inSeconds} с — файл слишком '
          'сложный или повреждён.'),
    );

class GeometryScreen extends StatefulWidget {
  final Project? project;
  final ValueChanged<Project> onChange;

  /// Конвертер закрытых форматов; по умолчанию — реальный клиент
  /// к services/converter (в тестах передаётся заглушка).
  final Converter? converter;

  /// Полный разбор импортированного файла: (контуры, ошибки).
  /// По умолчанию — разбор байтов (parseBytes) + анализ технологичности
  /// через [heavy] (изолят на desktop, главный поток на web).
  /// В widget-тестах передаётся детерминированная заглушка: тяжёлый вызов
  /// не завершается под fakeAsync. Аргумент — строка [display] источника.
  final Future<({List<CamPath> paths, List<Issue> issueList})> Function(
      String display)? processOverride;

  /// Хранилище проектов: нужно для облачного синхронизации исходника
  /// (`uploadSource`, §12.5) и скачивания оригинала (`inputFileId`).
  /// null / без api — локальный режим, поведение не меняется.
  final ProjectStore? store;

  const GeometryScreen(
      {super.key,
      required this.project,
      required this.onChange,
      this.converter,
      this.processOverride,
      this.store});

  @override
  State<GeometryScreen> createState() => _GeometryScreenState();
}

class _GeometryScreenState extends State<GeometryScreen> {
  final _pathCtrl = TextEditingController();
  bool _busy = false;
  String _status = '';

  /// Вылеченный мастер-элемент распознанного массива (для отображения
  /// отдельным «слоем» MASTER поверх копий ARRAY на холсте).
  List<CamPath>? _master;

  /// Адрес сервера конвертации (правится кнопкой-шестерёнкой).
  String _converterBase = ConverterApi.defaultBaseUrl();

  /// Состояние локального сервера конвертации: null — не проверялся/не
  /// запущен, true — отвечает, false — запуск не удался.
  bool? _serverUp;

  /// Идёт запуск сервера конвертации.
  bool _serverStarting = false;

  Project get p => widget.project ?? Project(name: '');

  /// Конвертер: явный (тесты) либо клиент на текущий адрес сервера.
  Converter get _converter =>
      widget.converter ?? ConverterApi(baseUrl: _converterBase);

  /// Запись в журнал приложения (окно «Журнал событий» в шапке): ошибки
  /// дублируются туда же, где они показаны в статусе экрана, но с временем
  /// и возможностью скопировать целиком.
  void _log(String message, {LogLevel level = LogLevel.info}) =>
      AppLog.instance.record('Геометрия', message, level: level);

  /// Технологические поля материала и сдвиг макета (блок «Ширина материала»).
  double _fieldLeft = 5.0;
  double _fieldRight = 5.0;
  double _layoutShift = 0.0;
  final _fieldLeftCtrl = TextEditingController(text: '5');
  final _fieldRightCtrl = TextEditingController(text: '5');
  final _shiftCtrl = TextEditingController(text: '0');

  @override
  void dispose() {
    _fieldLeftCtrl.dispose();
    _fieldRightCtrl.dispose();
    _shiftCtrl.dispose();
    super.dispose();
  }

  /// Ширина макета (мм): от крайнего левого до крайнего правого элемента
  /// распознанного массива (по фактическим смещениям копий + ширина мастера).
  static double? _patternSpanX(PatternResult pat) {
    if (!pat.isArray) return null;
    if (pat.offsets.isNotEmpty) {
      var minX = pat.offsets.first.x, maxX = pat.offsets.first.x;
      for (final o in pat.offsets) {
        if (o.x < minX) minX = o.x;
        if (o.x > maxX) maxX = o.x;
      }
      final span = maxX - minX + pat.labelW;
      return span > 0 ? span : pat.labelW;
    }
    if (pat.cols > 1 && pat.stepX > 0) {
      return (pat.cols - 1) * pat.stepX + pat.labelW;
    }
    return pat.labelW;
  }

  /// Массив извлечён: рабочий вектор для поиска ошибок/лечения/исправлений —
  /// мастер-элемент из слоя извлечённого массива (pattern.masterPaths).
  /// Копии (слой ARRAY) идентичны мастеру и пересобираются по закону.
  bool _arrayModeFor(Project p) {
    final pat = p.pattern;
    return pat?.isArray == true && (pat?.masterPaths.isNotEmpty ?? false);
  }

  @override
  Widget build(BuildContext context) {
    final project = widget.project;
    if (project == null) {
      return const Center(
          child: Text('Создайте или откройте проект на вкладке «Проекты».'));
    }
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(8),
          child: Row(
            children: [
              if (!isWeb) ...[
                Expanded(
                  child: Tooltip(
                    message: 'Путь к векторному файлу. Поддерживаются DXF, '
                        'SVG, PDF, AI, CDR, EPS. Файл удобнее выбрать кнопкой '
                        '«Обзор…».',
                    child: TextField(
                      controller: _pathCtrl,
                      decoration: const InputDecoration(
                          labelText: 'Путь к файлу (DXF/SVG/PDF/AI/CDR/EPS)',
                          helperText:
                              'AI/CDR/EPS конвертируются автоматически',
                          border: OutlineInputBorder(),
                          isDense: true),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Tooltip(
                  message: 'Загрузить и разобрать выбранный векторный файл.',
                  child: FilledButton(
                      onPressed: _busy ? null : _import,
                      child: const Text('Импорт')),
                ),
                const SizedBox(width: 8),
                Tooltip(
                  message: 'Выбрать векторный файл в диалоге — без ручного '
                      'ввода пути.',
                  child: OutlinedButton.icon(
                      onPressed: _busy ? null : _browse,
                      icon: const Icon(Icons.folder_open, size: 18),
                      label: const Text('Обзор')),
                ),
                const SizedBox(width: 8),
              ] else ...[
                const Expanded(
                  child: Text(
                      'Файл: DXF/SVG/PDF/AI/CDR/EPS — выберите файл кнопкой '
                      '«Импорт файла». AI/CDR/EPS конвертируются на сервере.'),
                ),
                const SizedBox(width: 8),
                Tooltip(
                  message: 'Загрузить и разобрать векторный файл.',
                  child: FilledButton.icon(
                      onPressed: _busy ? null : _import,
                      icon: const Icon(Icons.upload_file, size: 18),
                      label: const Text('Импорт файла')),
                ),
                const SizedBox(width: 8),
              ],
              if (widget.store?.api != null &&
                  widget.project?.inputFileId != null) ...[
                const SizedBox(width: 8),
                Tooltip(
                  message: 'Скачать исходный файл проекта из облака.',
                  child: OutlinedButton.icon(
                      onPressed: _busy ? null : _downloadOriginal,
                      icon: const Icon(Icons.download, size: 18),
                      label: const Text('Скачать оригинал')),
                ),
              ],
              _serverButton(),
            ],
          ),
        ),
        if (_busy) const LinearProgressIndicator(),
        if (_status.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Text(_status, style: const TextStyle(color: Colors.blueGrey)),
          ),
        Expanded(
          child: Row(
            children: [
              Expanded(
                flex: 3,
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: GeometryCanvas(
                    paths: _canvasPaths(project),
                    issues: project.issues,
                  ),
                ),
              ),
              Expanded(
                flex: 2,
                child: Column(
                  children: [
                    _actionRow(project),
                    if (_arrayModeFor(project)) ...[
                      const SizedBox(height: 4),
                      _webPanel(project),
                    ],
                    const Divider(),
                    Expanded(child: _issueList(project)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// Пути для холста: при распознанном массиве рисуем слой копий (ARRAY) и
  /// поверх — мастер-элемент (слой MASTER); иначе — вылеченные/исходные.
  List<CamPath> _canvasPaths(Project project) {
    final master = _master;
    if (project.arrayPaths.isNotEmpty || (master?.isNotEmpty ?? false)) {
      return [
        ...project.arrayPaths,
        if (master != null) ...master,
      ];
    }
    return project.healedPaths.isNotEmpty
        ? project.healedPaths
        : project.rawPaths;
  }

  /// Габариты (мм) набора контуров по ограничивающему прямоугольнику.
  static ({double w, double h}) _pathsBounds(List<CamPath> paths) {
    var minX = double.infinity, minY = double.infinity;
    var maxX = double.negativeInfinity, maxY = double.negativeInfinity;
    for (final p in paths) {
      for (final v in p.points) {
        if (v.x < minX) minX = v.x;
        if (v.y < minY) minY = v.y;
        if (v.x > maxX) maxX = v.x;
        if (v.y > maxY) maxY = v.y;
      }
    }
    final ok = paths.isNotEmpty && minX <= maxX && minY <= maxY;
    return (
      w: ok ? maxX - minX : 0,
      h: ok ? maxY - minY : 0,
    );
  }

  /// Поле-число для блока «Ширина материала» с всплывающей подсказкой.
  Widget _webField(TextEditingController ctrl, String label, String tip,
      ValueChanged<String> onChanged) {
    return Tooltip(
      message: tip,
      child: SizedBox(
        width: 128,
        child: TextField(
          controller: ctrl,
          decoration: InputDecoration(
              labelText: label,
              border: const OutlineInputBorder(),
              isDense: true),
          keyboardType: TextInputType.number,
          onChanged: onChanged,
        ),
      ),
    );
  }

  /// Блок «Ширина материала»: показывается после распознавания массива.
  /// Ширина макета берётся от крайнего левого до крайнего правого элемента,
  /// рекомендуемая ширина полотна = макет + поля слева и справа; сдвиг
  /// макета перемещает его вправо/влево относительно оси симметрии.
  Widget _webPanel(Project project) {
    final pat = project.pattern;
    if (pat == null || !pat.isArray) return const SizedBox.shrink();
    final span = _patternSpanX(pat);
    if (span == null || span <= 0) return const SizedBox.shrink();

    final width = span + _fieldLeft + _fieldRight;
    // Сдвиг ограничен полями, чтобы макет не выходил за край материала.
    final shiftMax = _fieldRight;
    final shiftMin = -_fieldLeft;
    final d = _layoutShift > shiftMax
        ? shiftMax
        : (_layoutShift < shiftMin ? shiftMin : _layoutShift);
    final leftEff = _fieldLeft + d;
    final rightEff = _fieldRight - d;
    final canApply = width > 0 && _fieldLeft >= 0 && _fieldRight >= 0;

    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Ширина материала',
              style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 2),
          Text(
              'Макет (крайний левый ↔ крайний правый элемент): '
              '${span.toStringAsFixed(1)} мм',
              style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 4),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              _webField(
                  _fieldLeftCtrl,
                  'Поле слева, мм',
                  'Технологическое поле от левого края материала до левого '
                      'элемента макета (редактируется).',
                  (v) => setState(() => _fieldLeft = double.tryParse(v) ?? 0)),
              _webField(
                  _fieldRightCtrl,
                  'Поле справа, мм',
                  'Технологическое поле от правого края материала до правого '
                      'элемента макета (редактируется).',
                  (v) =>
                      setState(() => _fieldRight = double.tryParse(v) ?? 0)),
              _webField(
                  _shiftCtrl,
                  'Сдвиг макета, мм',
                  'Сдвиг макета вправо (+) или влево (−) относительно '
                      'продольной оси симметрии материала. Движение макета '
                      'вправо увеличивает левое поле и уменьшает правое.',
                  (v) => setState(() => _layoutShift = double.tryParse(v) ?? 0)),
            ],
          ),
          const SizedBox(height: 4),
          Text(
              'Рекомендуемая ширина материала: '
              '${width.toStringAsFixed(1)} мм'
              '${d == 0 ? '' : '   (после сдвига: слева ${leftEff.toStringAsFixed(1)} мм · справа ${rightEff.toStringAsFixed(1)} мм)'}',
              style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 2),
          Align(
            alignment: Alignment.centerRight,
            child: OutlinedButton.icon(
              onPressed: _busy || !canApply
                  ? null
                  : () => _applyWebWidth(project, span, width),
              icon: const Icon(Icons.arrow_forward, size: 16),
              label: const Text('Применить к раскрою (полотно)'),
            ),
          ),
        ],
      ),
    );
  }

  /// «Применить к раскрою»: рекомендованная ширина материала (макет + поля)
  /// записывается в параметр «Полотно» (webWidth) раскроя.
  void _applyWebWidth(Project project, double span, double width) {
    final webWidth = (width * 100).roundToDouble() / 100;
    widget.onChange(Project(
      name: project.name,
      inputFile: project.inputFile,
      params: project.params.copyWith(webWidth: webWidth),
      rawPaths: project.rawPaths,
      healedPaths: project.healedPaths,
      issues: project.issues,
      pattern: project.pattern,
      arrayPaths: project.arrayPaths,
      calc: project.calc,
      variants: project.variants,
      selectedVariantIndex: project.selectedVariantIndex,
    ));
    if (mounted) {
      setState(() => _status = 'Ширина материала $webWidth мм (макет '
          '${span.toStringAsFixed(1)} мм + поля) применена в «Полотно» раскроя.');
    }
    _log('Раскрой: рекомендованная ширина материала $webWidth мм = макет '
        '${span.toStringAsFixed(1)} мм + поле слева ${_fieldLeft.toStringAsFixed(1)} '
        'мм + поле справа ${_fieldRight.toStringAsFixed(1)} мм — применена в '
        '«Полотно» (${_layoutShift == 0 ? 'без сдвига' : 'сдвиг макета ${_layoutShift.toStringAsFixed(1)} мм'})');
  }

  Widget _actionRow(Project project) {
    return Wrap(
      spacing: 8,
      runSpacing: 6,
      children: [
        Tooltip(
          message: 'Найти отдельный элемент (мастер) и закон расположения '
              'массива (ряды×колонки, шаг, зазоры), вылечить только мастер и '
              'размножить его по закону на отдельный слой; размеры этикетки '
              'автоматически попадут в параметры раскроя.',
          child: ActionChip(
              avatar: const Icon(Icons.grid_on, size: 18),
              label: const Text('Распознать массив'),
              onPressed:
                  _busy || project.rawPaths.isEmpty ? null : () => _recognize(project)),
        ),
        Tooltip(
          message: 'Замкнуть разомкнутые контуры, удалить «мусор» и скруглить '
              'острые углы. Результат — контуры, готовые к раскрою.',
          child: ActionChip(
              avatar: const Icon(Icons.healing, size: 18),
              label: const Text('Вылечить всё'),
              onPressed: _busy ? null : () => _heal(project)),
        ),
        Tooltip(
          message: 'Пересобрать сетку из мастер-контура (массив на отдельном '
              'слое ARRAY). Используется, если после распознавания вы '
              'изменили параметры раскроя.',
          child: ActionChip(
              avatar: const Icon(Icons.copy_all, size: 18),
              label: const Text('Сгенерировать сетку'),
              onPressed: _busy ||
                      project.pattern == null ||
                      !project.pattern!.isArray
                  ? null
                  : () => _generateGrid(project)),
        ),
      ],
    );
  }

  Widget _issueList(Project project) {
    // При извлечённом массиве ошибки ищутся ТОЛЬКО по мастер-элементу.
    final header = _arrayModeFor(project)
        ? 'Ошибки мастер-элемента (этикетка)'
        : 'Ошибки технологичности';
    final Widget body;
    if (project.issues.isEmpty) {
      body = const Center(child: Text('Ошибок не найдено.'));
    } else {
      body = ListView.builder(
        itemCount: project.issues.length,
        itemBuilder: (_, i) {
          final issue = project.issues[i];
          final color = switch (issue.severity) {
            'error' => Colors.red,
            'warning' => Colors.orange,
            _ => Colors.amber,
          };
          return ListTile(
            dense: true,
            leading: Icon(Icons.circle, color: color, size: 12),
            title: Text(issue.message,
                style: const TextStyle(fontSize: 12)),
            subtitle: Text(issue.suggestion,
                style: const TextStyle(fontSize: 11)),
            trailing: issue.fixable
                ? TextButton(
                    onPressed: _busy
                        ? null
                        : () => _fixIssue(project, issue),
                    child: const Text('Исправить'))
                : null,
          );
        },
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
          child: Text(header,
              style: Theme.of(context).textTheme.titleSmall),
        ),
        const SizedBox(height: 4),
        Expanded(child: body),
      ],
    );
  }

  /// Источник импорта: на web — браузерный выбор файла (байты), на desktop —
  /// путь из поля ввода (проверка существования) + чтение байтов.
  Future<void> _import() async {
    final project = widget.project;
    if (project == null) return;

    final _ImportFile src;
    if (isWeb) {
      final pick = await pickSingleFile();
      if (pick == null || !mounted) return;
      src = _ImportFile(
          name: pick.name, bytes: pick.bytes, display: pick.name);
    } else {
      final path = _pathCtrl.text.trim();
      if (path.isEmpty || !await exists(path)) {
        setState(() => _status = 'Файл не найден: $path');
        _log('Файл не найден: $path', level: LogLevel.error);
        return;
      }
      if (mounted) {
        setState(() => _status = 'Чтение файла…');
      }
      final bytes = await readBytes(path);
      src = _ImportFile(name: _pathBase(path), bytes: bytes, display: path);
    }

    // Закрытые форматы (AI/CDR/EPS) — серверная конвертация в SVG (спека §3,
    // ШАГ 1), затем обычный разбор доменом.
    if (ConverterApi.isClosedFormat(src.name)) {
      await _importClosed(src, project);
    } else {
      await _importLocal(src, project);
    }
  }

  /// Локальные форматы (DXF/SVG/PDF/AI-PDF): прямой разбор доменом.
  Future<void> _importLocal(_ImportFile src, Project project) async {
    setState(() {
      _busy = true;
      _master = null; // новый файл — старый мастер массива недействителен
      _status = 'Разбор файла…';
    });
    try {
      final res = await _parseAndApply(src, project);
      // Облачный режим: исходник уходит в services/api (§12.5), id — в проект.
      await _syncSource(src, res.project);
    } catch (e) {
      if (mounted) setState(() => _status = 'Ошибка разбора: $e');
      _log('Ошибка разбора: $e', level: LogLevel.error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// AI/CDR/EPS: конвертация через services/converter, затем разбор SVG.
  Future<void> _importClosed(_ImportFile src, Project project) async {
    setState(() {
      _busy = true;
      _master = null; // новый файл — старый мастер массива недействителен
      _status = 'Конвертация закрытого формата на сервере…';
    });
    _log('Конвертация закрытого формата…');
    final conv = _converter;
    try {
      final svg = await conv.convertToSvg(
          fileName: src.name, bytes: src.bytes);
      // Оригинал закрытого формата уже в облаке (multipart ApiConverter) —
      // забираем file_id, чтобы проект знал исходник («Скачать оригинал»).
      final originalId =
          conv is ApiConverter ? conv.lastOriginalFileId : null;
      // SVG разбирается сразу из байтов (временный файл не нужен).
      final svgSource = _ImportFile(
        name: 'converted.svg',
        bytes: svg,
        display: src.display,
      );
      final parsed = await _parseAndApply(svgSource, project,
          progress: 'Разбор сконвертированного SVG…', fileId: originalId);
      final summary = parsed.summary;
      if (mounted) {
        setState(() => _status = 'Конвертация успешна. $summary');
      }
      _log('Конвертация успешна. $summary');
    } on ConverterException catch (e) {
      // .ai может оказаться PDF-совместимым — пробуем локальный разбор.
      if (src.name.toLowerCase().endsWith('.ai')) {
        try {
          // Если загрузка в облако успела до сбоя конвертации — ссылаемся
          // на неё и не грузим оригинал повторно.
          final uploadedId =
              conv is ApiConverter ? conv.lastOriginalFileId : null;
          final res = await _parseAndApply(src, project,
              progress: 'Локальный разбор AI…', fileId: uploadedId);
          if (uploadedId == null) {
            await _syncSource(src, res.project);
          }
          if (mounted) {
            setState(() => _status =
                'Сервер недоступен — AI разобран локально как PDF. ${res.summary}');
          }
        } catch (_) {
          if (mounted) {
            setState(() => _status = 'Ошибка конвертации: ${e.message}');
          }
          _log('Ошибка конвертации (локальный разбор AI тоже не удался): '
              '${e.message}',
              level: LogLevel.error);
        }
      } else {
        if (mounted) {
          setState(() => _status = 'Ошибка конвертации: ${e.message}');
        }
        _log('Ошибка конвертации: ${e.message}', level: LogLevel.error);
      }
    } catch (e) {
      if (mounted) setState(() => _status = 'Ошибка: $e');
      _log('Ошибка импорта: $e', level: LogLevel.error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Разбор [source] доменом и запись результата в проект.
  /// Источник проекта ([Project.inputFile]) — [source.display] (исходный файл
  /// пользователя). Разбор и анализ идут отдельными шагами с таймаутом, чтобы
  /// вместо «вечной загрузки» было видно текущий этап и понятную ошибку.
  /// Разобрать байты и применить к проекту: возвращает обновлённый проект
  /// и сводку (нужно для облачной синхронизации исходника).
  /// [fileId] — id уже загруженного в облако оригинала (закрытые форматы
  /// через `ApiConverter`); для локальных форматов null — его заполняет
  /// [_syncSource] после своей загрузки.
  Future<({Project project, String summary})> _parseAndApply(
      _ImportFile source, Project project,
      {String progress = 'Разбор файла…', String? fileId}) async {
    if (mounted) setState(() => _status = progress);
    final process = widget.processOverride;

    List<CamPath> paths;
    List<Issue> issueList;
    if (process != null) {
      // Тестовая заглушка: один вызов возвращает и контуры, и ошибки.
      final result = await process(source.display);
      paths = result.paths;
      issueList = result.issueList;
    } else {
      try {
        paths = await _parseBytesHeavy(source.name, source.bytes)
            .timeout(_fileTimeout);
      } on TimeoutException {
        throw StateError('Разбор файла занял больше ${_fileTimeout.inSeconds} с'
            ' — файл слишком сложный или повреждён. Упростите его или '
            'конвертируйте в DXF/SVG.');
      }
      if (mounted) setState(() => _status = 'Анализ технологичности…');
      try {
        issueList =
            await _heavyAnalyze(paths).timeout(_fileTimeout);
      } on TimeoutException {
        throw StateError('Анализ ошибок занял больше ${_fileTimeout.inSeconds}'
            ' с — слишком много контуров в файле.');
      }
    }

    final updated = Project(
      name: project.name,
      inputFile: source.display,
      params: project.params,
      rawPaths: paths,
      healedPaths: const [], // новый файл — прежнее лечение недействительно
      issues: issueList,
      pattern: null,
      arrayPaths: const [],
      calc: project.calc,
      variants: project.variants,
      selectedVariantIndex: project.selectedVariantIndex,
      // Новый файл: прежняя ссылка на исходник в облаке недействительна.
      // Для закрытых форматов id уже известен (загрузка шла в ApiConverter),
      // для локальных появится после [_syncSource].
      inputFileId: fileId,
    );
    final summary =
        'Загружено контуров: ${paths.length}; ошибок: ${issueList.length}.';
    if (mounted) setState(() => _status = summary);
    _log(summary);
    widget.onChange(updated);
    return (project: updated, summary: summary);
  }

  /// Облачная синхронизация исходника (`flutter-web-adapt`: picker →
  /// multipart → метаданные, §12.5): после успешного локального разбора файл
  /// уходит в `services/api`, `file_id` сохраняется в проекте — кнопка
  /// «Скачать оригинал» качает blob через `GET /api/files/{id}/download`.
  /// Вне облачного режима — no-op; ошибки не ломают импорт (только журнал).
  Future<void> _syncSource(_ImportFile src, Project project) async {
    final store = widget.store;
    if (store?.api == null) return;
    try {
      final fileId = await store!.uploadSource(project, src.name, src.bytes);
      if (fileId == null) return;
      project.inputFileId = fileId;
      widget.onChange(project); // сохранение области в проекте
      _log('Исходник загружен в облако: ${src.name} (файл $fileId).');
      if (mounted) setState(() {}); // показать кнопку «Скачать оригинал»
    } catch (e) {
      _log('Исходник не загружен в облако: $e', level: LogLevel.warning);
    }
  }

  /// Скачать оригинальный файл из облака (`GET /files/{id}/download`).
  Future<void> _downloadOriginal() async {
    final store = widget.store;
    final p = widget.project;
    final fileId = p?.inputFileId;
    if (store?.api == null || p == null || fileId == null) return;
    setState(() => _busy = true);
    try {
      final token = await store!.tokenProvider?.call();
      if (token == null || token.isEmpty) {
        throw StateError('Сессия неактивна: вход в аккаунт для скачивания.');
      }
      final bytes = await store.api!.downloadFile(token, fileId);
      final name = p.inputFile.isEmpty ? 'original.bin' : p.inputFile;
      final base = name.split('/').last;
      final where = await saveReport(store.directory, base, bytes);
      if (mounted) {
        setState(() => _status = isWeb
            ? 'Оригинал скачан: $base'
            : 'Оригинал сохранён: $where');
      }
      _log(isWeb ? 'Оригинал скачан: $base' : 'Оригинал сохранён: $where');
    } catch (e) {
      if (mounted) setState(() => _status = 'Ошибка скачивания: $e');
      _log('Ошибка скачивания оригинала: $e', level: LogLevel.error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Выбор векторного файла встроенным диалогом (без внешних плагинов).
  /// Только desktop: на web файл выбирается браузерным диалогом [pickSingleFile].
  Future<void> _browse() async {
    if (isWeb) return;
    final picked = await showDialog<String>(
      context: context,
      builder: (_) => _VectorFileDialog(startDir: homeDir),
    );
    if (picked == null || !mounted) return;
    setState(() {
      _pathCtrl.text = picked;
      _status = 'Выбран файл: $picked. Нажмите «Импорт».';
    });
    _log('Выбран файл: $picked');
  }

  /// Кнопка управления сервером конвертации AI/CDR/EPS.
  /// Локальный адрес: «Запустить сервер» (поднять uvicorn на этом ПК).
  /// Удалённый адрес: «Проверить сервер» (проверить доступность).
  /// Адрес пользователю не показывается (скрыт).
  Widget _serverButton() {
    final local = ConverterServer.isLocal(_converterBase);
    final Widget icon;
    final String label;
    if (_serverStarting) {
      icon = const SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(strokeWidth: 2));
      label = local ? 'Запуск сервера…' : 'Проверка сервера…';
    } else if (_serverUp == true) {
      icon = const Icon(Icons.check_circle, size: 18, color: Colors.green);
      label = 'Сервер работает';
    } else {
      icon = const Icon(Icons.play_arrow, size: 18);
      label = local ? 'Запустить сервер' : 'Проверить сервер';
    }
    return Tooltip(
      message: local
          ? 'Проверить и, если не запущен, поднять локальный сервер '
              'конвертации AI/CDR/EPS'
          : 'Проверить доступность сервера конвертации AI/CDR/EPS',
      child: OutlinedButton.icon(
        onPressed: _serverStarting ? null : _startServer,
        icon: icon,
        label: Text(label),
      ),
    );
  }

  /// Проверка сервера конвертации: для локального адреса — запуск uvicorn,
  /// для удалённого — только проверка доступности. Результат — в статус
  /// экрана и в журнал событий (без показа адреса).
  Future<void> _startServer() async {
    if (_serverStarting) return;
    setState(() {
      _serverStarting = true;
      _serverUp = null;
    });
    _log('Проверка сервера конвертации…');
    try {
      final server = ConverterServer(baseUrl: _converterBase);
      final String? err;
      if (ConverterServer.isLocal(_converterBase)) {
        err = await server.ensureRunning();
      } else {
        // Удалённый адрес: запускать локально бессмысленно — только проба.
        err = (await server.probe()) ? null : 'сервер недоступен';
      }
      if (!mounted) return;
      if (err == null) {
        setState(() {
          _serverUp = true;
          _status = 'Сервер конвертации работает. Импорт AI/CDR/EPS доступен.';
        });
        _log('Сервер конвертации работает.');
      } else {
        setState(() {
          _serverUp = false;
          _status = ConverterServer.isLocal(_converterBase)
              ? 'Ошибка запуска сервера конвертации: $err'
              : 'Сервер конвертации недоступен: $err. Проверьте сеть.';
        });
        _log('Сервер конвертации недоступен: $err',
            level: LogLevel.error);
      }
    } finally {
      if (mounted) setState(() => _serverStarting = false);
    }
  }

  Future<void> _heal(Project project) async {
    // Массив извлечён — дальше работаем ТОЛЬКО с мастер-элементом из слоя
    // извлечённого массива (копии идентичны мастеру и пересобираются по
    // закону), а не со всем листом.
    if (_arrayModeFor(project)) {
      await _healMasterAndRebuild(project, project.pattern!.masterPaths);
      return;
    }
    setState(() {
      _busy = true;
      _master = null; // после полного лечения мастер-элемент пересчитывается
      _status = 'Лечение геометрии…';
    });
    _log('Лечение геометрии…');
    try {
      final healed = await _timed(_heavyHeal(project.rawPaths),
          'Лечение геометрии');
      final issues =
          await _timed(_heavyAnalyze(healed), 'Анализ ошибок');
      widget.onChange(Project(
        name: project.name,
        inputFile: project.inputFile,
        params: project.params,
        rawPaths: project.rawPaths,
        healedPaths: healed,
        issues: issues,
        pattern: project.pattern,
        arrayPaths: project.arrayPaths,
        calc: project.calc,
        variants: project.variants,
        selectedVariantIndex: project.selectedVariantIndex,
      ));
      if (mounted) {
        setState(() => _status = 'Вылечено: ${healed.length} контуров.');
      }
      _log('Вылечено: ${healed.length} контуров.');
    } on TimeoutException catch (e) {
      if (mounted) setState(() => _status = 'Ошибка: $e');
      _log('Ошибка лечения (${project.inputFile}): $e',
          level: LogLevel.error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Массив извлечён: лечит мастер-элемент [base] и пересобирает слой ARRAY.
  Future<void> _healMasterAndRebuild(
      Project project, List<CamPath> base) async {
    setState(() {
      _busy = true;
      _status = 'Лечение мастер-элемента (массив извлечён)…';
    });
    _log('Лечение мастер-элемента — рабочий вектор из извлечённого массива');
    try {
      final healed =
          await _timed(_heavyHeal(base), 'Лечение мастер-элемента');
      await _commitMaster(project, healed);
    } on TimeoutException catch (e) {
      if (mounted) setState(() => _status = 'Ошибка: $e');
      _log('Ошибка лечения мастер-элемента (${project.inputFile}): $e',
          level: LogLevel.error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Сохраняет новый мастер [healedAll] (слой MASTER), считает ошибки ТОЛЬКО
  /// по нему и пересобирает массив по тому же закону (слой ARRAY).
  Future<void> _commitMaster(Project project, List<CamPath> healedAll) async {
    final pat = project.pattern;
    if (pat == null || !pat.isArray) return;
    final cleaned = <CamPath>[
      for (final p in healedAll)
        if (p.isClosed && p.points.length >= 3)
          CamPath(List.of(p.points), isClosed: true, layerName: 'MASTER')
    ];
    if (cleaned.isEmpty) {
      if (mounted) {
        setState(() => _status = 'Не удалось получить замкнутый '
            'мастер-элемент — проверьте геометрию файла.');
      }
      _log('Мастер-элемент не дал замкнутых контуров',
          level: LogLevel.error);
      return;
    }
    if (mounted) setState(() => _status = 'Анализ мастер-элемента…');
    final issues =
        await _timed(_heavyAnalyze(cleaned), 'Анализ мастер-элемента');
    if (mounted) setState(() => _status = 'Размножение по закону…');
    final cols = pat.cols < 1 ? 1 : pat.cols;
    final rows = pat.rows < 1 ? 1 : pat.rows;
    final stepX = pat.stepX > 0 ? pat.stepX : pat.labelW;
    final stepY = pat.stepY > 0 ? pat.stepY : pat.labelH;
    final grid = await _timed(
        _heavyGrid(cleaned,
            cols: cols, rows: rows, stepX: stepX, stepY: stepY),
        'Размножение по закону');
    final pattern = PatternResult(
      isArray: true,
      masterPaths: cleaned,
      offsets: pat.offsets,
      rows: rows,
      cols: cols,
      stepX: stepX,
      stepY: stepY,
      gapX: pat.gapX,
      gapY: pat.gapY,
      count: grid.length,
      labelW: pat.labelW,
      labelH: pat.labelH,
      masterArea: pat.masterArea,
    );
    widget.onChange(Project(
      name: project.name,
      inputFile: project.inputFile,
      params: project.params,
      rawPaths: project.rawPaths,
      healedPaths: project.healedPaths,
      issues: issues,
      pattern: pattern,
      arrayPaths: grid,
      calc: project.calc,
      variants: project.variants,
      selectedVariantIndex: project.selectedVariantIndex,
    ));
    if (mounted) {
      setState(() {
        _master = cleaned;
        _status = 'Мастер-элемент обновлён: ${cleaned.length} контуров, '
            'ошибок ${issues.length}. Массив пересобран: ${grid.length} копий.';
      });
    }
    _log('Мастер-элемент обновлён: ${cleaned.length} контуров, ошибок '
        '${issues.length}; массив пересобран: ${grid.length} копий.');
  }

  /// Распознавание массива: найти отдельный элемент (мастер) и закон
  /// расположения (ряды×колонки, шаг, зазоры) → вылечить ТОЛЬКО мастер →
  /// размножить его по закону на отдельный слой ('ARRAY') → автоматически
  /// заполнить параметры раскроя (labelW/H, зазоры).
  Future<void> _recognize(Project project) async {
    final source = project.healedPaths.isNotEmpty
        ? project.healedPaths
        : project.rawPaths;
    if (source.isEmpty) {
      if (mounted) {
        setState(() => _status = 'Сначала импортируйте векторный файл.');
      }
      _log('Распознавание массива: файл не импортирован',
          level: LogLevel.warning);
      return;
    }
    setState(() {
      _busy = true;
      _master = null;
      _status = 'Распознавание массива…';
    });
    _log('Распознавание массива…');
    try {
      final result = await _timed(_heavyRecognize(source),
          'Распознавание массива');
      if (!result.isArray || result.masterPaths.isEmpty) {
        if (mounted) {
          setState(() => _status = 'Массив не найден. Совет: выполните '
              '«Вылечить всё» и повторите, либо файл действительно содержит '
              'одиночный контур.');
        }
        _log('Массив не найден в файле', level: LogLevel.warning);
        return;
      }

      // 1) Лечим ТОЛЬКО мастер-элемент (не все копии) и помечаем его
      //    отдельным слоем MASTER для отображения и экспорта. Открытые
      //    «хвосты»-артефакты лечения отбрасываем: элементу нужны только
      //    замкнутые компоненты (внешний контур и отверстия).
      if (mounted) setState(() => _status = 'Лечение мастер-элемента…');
      _log('Лечение мастер-элемента…');
      final healedAll = (await _timed(
              _heavyHeal(result.masterPaths), 'Лечение мастер-элемента'))
          .map((p) => CamPath(List.of(p.points),
              isClosed: p.isClosed, layerName: 'MASTER'))
          .toList();
      final healedMaster = [
        for (final p in healedAll)
          if (p.isClosed && p.points.length >= 3) p
      ];
      if (healedMaster.isEmpty) {
        if (mounted) {
          setState(() => _status = 'Не удалось вылечить мастер-элемент — '
              'проверьте геометрию файла.');
        }
        _log('Не удалось вылечить мастер-элемент — проверьте геометрию файла.',
            level: LogLevel.error);
        return;
      }

      // 2) Технологические ошибки считаем по мастеру: копии идентичны.
      if (mounted) setState(() => _status = 'Анализ мастер-элемента…');
      _log('Анализ мастер-элемента…');
      final masterIssues = await _timed(
          _heavyAnalyze(healedMaster), 'Анализ мастер-элемента');

      // 3) Размножение по распознанному закону на слой 'ARRAY'.
      if (mounted) setState(() => _status = 'Размножение по закону…');
      _log('Размножение по закону…');
      final cols = result.cols < 1 ? 1 : result.cols;
      final rows = result.rows < 1 ? 1 : result.rows;
      final stepX = result.stepX > 0 ? result.stepX : result.labelW;
      final stepY = result.stepY > 0 ? result.stepY : result.labelH;
      final grid = await _timed(
          _heavyGrid(healedMaster,
              cols: cols, rows: rows, stepX: stepX, stepY: stepY),
          'Размножение по закону');

      // 4) Автозаполнение параметров раскроя из массива (этикетка из
      //    вылеченного мастера, зазоры = шаг − этикетка).
      final b = _pathsBounds(healedMaster);
      final labelW = b.w > 0 ? b.w : result.labelW;
      final labelH = b.h > 0 ? b.h : result.labelH;
      final gapX = stepX > 0
          ? (stepX - labelW).clamp(0.0, stepX).toDouble()
          : 0.0;
      final gapY = stepY > 0
          ? (stepY - labelH).clamp(0.0, stepY).toDouble()
          : 0.0;
      final params = project.params.copyWith(
        labelW: labelW,
        labelH: labelH,
        gapX: gapX,
        gapY: gapY,
      );

      final pattern = PatternResult(
        isArray: true,
        masterPaths: healedMaster,
        offsets: result.offsets,
        rows: rows,
        cols: cols,
        stepX: stepX,
        stepY: stepY,
        gapX: gapX,
        gapY: gapY,
        count: grid.length,
        labelW: labelW,
        labelH: labelH,
        masterArea: result.masterArea,
      );

      widget.onChange(Project(
        name: project.name,
        inputFile: project.inputFile,
        params: params,
        rawPaths: project.rawPaths,
        healedPaths: project.healedPaths,
        issues: masterIssues,
        pattern: pattern,
        arrayPaths: grid,
        calc: project.calc,
        variants: project.variants,
        selectedVariantIndex: project.selectedVariantIndex,
      ));
      if (mounted) {
        setState(() {
          _master = healedMaster;
          _status = 'Массив: ${rows}×${cols} (${grid.length} копий), этикетка '
              '${labelW.toStringAsFixed(1)}×${labelH.toStringAsFixed(1)} мм, '
              'шаг ${stepX.toStringAsFixed(1)}×${stepY.toStringAsFixed(1)} мм. '
              'Мастер вылечен и размножен по закону; параметры раскроя '
              'заполнены.';
        });
      }
      _log('Массив распознан: ${rows}×${cols} (${grid.length} копий), '
          'этикетка ${labelW.toStringAsFixed(1)}×${labelH.toStringAsFixed(1)} '
          'мм, шаг ${stepX.toStringAsFixed(1)}×${stepY.toStringAsFixed(1)} мм. '
          'Мастер вылечен и размножен; параметры раскроя заполнены.');
    } on TimeoutException catch (e) {
      if (mounted) setState(() => _status = 'Ошибка: $e');
      _log('Ошибка распознавания массива (${project.inputFile}): $e',
          level: LogLevel.error);
    } catch (e) {
      if (mounted) setState(() => _status = 'Ошибка распознавания: $e');
      _log('Ошибка распознавания (${project.inputFile}): $e',
          level: LogLevel.error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _generateGrid(Project project) async {
    final pattern = project.pattern!;
    if (!pattern.isArray || pattern.masterPaths.isEmpty) {
      setState(() => _status = 'Массив не распознан — сетку не построить.');
      _log('Массив не распознан — сетку не построить',
          level: LogLevel.warning);
      return;
    }
    setState(() {
      _busy = true;
      _status = 'Генерация сетки…';
    });
    _log('Генерация сетки…');
    try {
      // Размеры сетки считаем в UI-изоляте (дёшево), в изолят уходят только
      // готовые параметры.
      final rapport =
          computeRapportValue(project.params.zTeeth, project.params.cp);
      final rows = autoRowsForRapport(
          rapport, pattern.labelH, project.params.minGap);
      final cols = (project.params.webWidth /
              (pattern.labelW + project.params.gapX))
          .floor();
      final c = cols < 1 ? 1 : cols;
      final r = rows < 1 ? 1 : rows;
      final grid = await _heavyGrid(pattern.masterPaths,
          cols: c,
          rows: r,
          stepX: pattern.labelW + project.params.gapX,
          stepY: pattern.labelH + project.params.gapY);
      widget.onChange(Project(
        name: project.name,
        inputFile: project.inputFile,
        params: project.params,
        rawPaths: project.rawPaths,
        healedPaths: project.healedPaths,
        issues: project.issues,
        pattern: project.pattern,
        arrayPaths: grid,
        calc: project.calc,
        variants: project.variants,
        selectedVariantIndex: project.selectedVariantIndex,
      ));
      if (mounted) {
        setState(() => _status = 'Сетка: ${grid.length} контуров.');
      }
      _log('Сетка: ${grid.length} контуров.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _fixIssue(Project project, Issue issue) async {
    // Массив извлечён — исправляем ТОЛЬКО мастер-элемент и пересобираем
    // массив по закону (ошибки копий идентичны мастеру, лист не трогаем).
    if (_arrayModeFor(project)) {
      final base = project.pattern!.masterPaths;
      setState(() {
        _busy = true;
        _status = 'Применение исправления к мастер-элементу…';
      });
      _log('Исправление мастер-элемента (${issue.message})…');
      try {
        final fixed = await _heavyFix(base, issue);
        await _commitMaster(project, fixed);
        if (mounted) {
          setState(() => _status = 'Исправление применено к мастеру: '
              '${issue.message}. Массив пересобран.');
        }
        _log('Исправление применено к мастеру: ${issue.message}');
      } finally {
        if (mounted) setState(() => _busy = false);
      }
      return;
    }
    setState(() {
      _busy = true;
      _master = null; // геометрия изменилась — пересчитайте массив
      _status = 'Применение исправления…';
    });
    _log('Применение исправления…');
    try {
      final fixed = await _heavyFix(project.rawPaths, issue);
      widget.onChange(Project(
        name: project.name,
        inputFile: project.inputFile,
        params: project.params,
        rawPaths: fixed,
        healedPaths: project.healedPaths,
        issues: project.issues,
        pattern: project.pattern,
        arrayPaths: project.arrayPaths,
        calc: project.calc,
        variants: project.variants,
        selectedVariantIndex: project.selectedVariantIndex,
      ));
      if (mounted) {
        setState(() => _status = 'Исправление применено.');
      }
      _log('Исправление применено: ${issue.message}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}

/// Встроенный диалог выбора векторного файла (без внешних плагинов):
/// навигация по папкам, отбор по расширениям DXF/SVG/PDF/AI/CDR/EPS.
/// Файловая система — через платформенные [listDir]/[exists]/[isDir]
/// (компилируется и для web, хотя на web диалог не открывается).
class _VectorFileDialog extends StatefulWidget {
  final String startDir;
  const _VectorFileDialog({required this.startDir});

  @override
  State<_VectorFileDialog> createState() => _VectorFileDialogState();
}

class _VectorFileDialogState extends State<_VectorFileDialog> {
  static const _exts = ['dxf', 'svg', 'pdf', 'ai', 'cdr', 'eps'];

  late String _cur;
  late final TextEditingController _pathCtrl;
  List<FsEntry> _entries = const [];
  bool _loading = false;
  String? _selected;
  bool _denied = false;

  @override
  void initState() {
    super.initState();
    _cur = widget.startDir;
    _pathCtrl = TextEditingController(text: _cur);
    _loadDir(_cur);
  }

  @override
  void dispose() {
    _pathCtrl.dispose();
    super.dispose();
  }

  static bool _isSupportedName(String name) {
    final n = name.toLowerCase();
    return _exts.any(n.endsWith);
  }

  /// Каталог на уровень выше; null — корень (подниматься некуда).
  static String? _parentOf(String path) {
    var p = path;
    if (p.endsWith('/') || p.endsWith(r'\')) {
      p = p.substring(0, p.length - 1);
    }
    final i = p.lastIndexOf(RegExp(r'[\\/]'));
    if (i <= 0) return null;
    return p.substring(0, i);
  }

  /// Чтение содержимого каталога [path] (async, платформенный список).
  Future<void> _loadDir(String path) async {
    setState(() {
      _loading = true;
      _denied = false;
    });
    try {
      var p = path;
      if (!await exists(p)) {
        // Папки нет (например, стартовый каталог) — домашний каталог.
        p = homeDir;
      }
      final list = await listDir(p);
      final dirs = <FsEntry>[];
      final files = <FsEntry>[];
      for (final e in list) {
        if (e.isDir) {
          dirs.add(e);
        } else if (_isSupportedName(e.name)) {
          files.add(e);
        }
      }
      int cmp(FsEntry a, FsEntry b) =>
          a.name.toLowerCase().compareTo(b.name.toLowerCase());
      dirs.sort(cmp);
      files.sort(cmp);
      if (!mounted) return;
      setState(() {
        _cur = p;
        _entries = [...dirs, ...files];
        _selected = null;
        _loading = false;
        _pathCtrl.text = p;
      });
    } catch (e) {
      AppLog.instance.error(
          'Геометрия', 'Не удалось прочитать папку «$path»: $e');
      if (!mounted) return;
      setState(() {
        _denied = true;
        _loading = false;
      });
    }
  }

  void _openDir(String path) {
    _loadDir(path);
  }

  Future<void> _submitPath() async {
    final text = _pathCtrl.text.trim();
    if (text.isEmpty) return;
    if (!await exists(text)) {
      setState(() => _denied = true);
      return;
    }
    if (isDir(text)) {
      _openDir(text);
      return;
    }
    if (_isSupportedName(_pathBase(text))) {
      Navigator.pop(context, text);
      return;
    }
    setState(() => _denied = true);
  }

  @override
  Widget build(BuildContext context) {
    final canGoUp = _parentOf(_cur) != null;
    return AlertDialog(
      title: const Text('Выбор векторного файла'),
      content: SizedBox(
        width: 640,
        height: 420,
        child: Column(
          children: [
            TextField(
              controller: _pathCtrl,
              onSubmitted: (_) => _submitPath(),
              decoration: InputDecoration(
                labelText: 'Папка или путь к файлу',
                isDense: true,
                border: const OutlineInputBorder(),
                prefixIcon: const Icon(Icons.folder, size: 20),
                errorText: _denied
                    ? 'Не удаётся открыть или файл не поддерживается'
                    : null,
              ),
            ),
            const SizedBox(height: 8),
            if (_loading)
              const Padding(
                padding: EdgeInsets.all(16),
                child: LinearProgressIndicator(),
              ),
            Expanded(
              child: ListView(
                children: [
                  if (canGoUp)
                    ListTile(
                      dense: true,
                      leading: const Icon(Icons.arrow_upward),
                      title: const Text('.. (на уровень выше)'),
                      onTap: () => _openDir(_parentOf(_cur)!),
                    ),
                  for (final e in _entries)
                    if (e.isDir)
                      ListTile(
                        dense: true,
                        leading: Icon(Icons.folder,
                            color: Colors.amber.shade800),
                        title: Text(e.name),
                        onTap: () => _openDir(e.path),
                      )
                    else
                      ListTile(
                        dense: true,
                        selected: _selected == e.path,
                        leading: const Icon(Icons.insert_drive_file, size: 20),
                        title: Text(e.name),
                        subtitle: const Text('Векторный файл'),
                        onTap: () => setState(() => _selected = e.path),
                      ),
                  if (!_loading && _entries.isEmpty && !_denied)
                    const Padding(
                      padding: EdgeInsets.all(16),
                      child: Text('В этой папке нет векторных файлов.'),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Отмена')),
        FilledButton(
          onPressed:
              _selected == null ? null : () => Navigator.pop(context, _selected),
          child: const Text('Выбрать'),
        ),
      ],
    );
  }
}
