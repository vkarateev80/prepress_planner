/// Экран «Проекты»: список, создание, открытие.
library;

import 'package:flutter/material.dart';

import '../../license/entitlement_store.dart';
import '../projects/project.dart';

class ProjectsScreen extends StatefulWidget {
  final ProjectStore store;
  final ValueChanged<Project> onOpen;
  final Project? current;
  final FeatureGate? gate;
  final VoidCallback? onNeedPro;
  const ProjectsScreen(
      {super.key,
      required this.store,
      required this.onOpen,
      this.current,
      this.gate,
      this.onNeedPro});

  @override
  State<ProjectsScreen> createState() => _ProjectsScreenState();
}

class _ProjectsScreenState extends State<ProjectsScreen> {
  List<String> _names = [];
  final _nameCtrl = TextEditingController(text: 'Новый проект');
  String _error = '';

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final names = await widget.store.listNames();
    if (mounted) setState(() => _names = names);
  }

  Future<void> _create() async {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) return;
    // Free-квота: 1 проект (проверка синхронная — раньше асинхронной).
    final gate = widget.gate;
    if (gate != null && !gate.hasProAccess && _names.isNotEmpty) {
      widget.onNeedPro?.call();
      return;
    }
    // Одноимённый проект не создаём: локально это была бы перезапись файла.
    if (await widget.store.exists(name)) {
      if (mounted) {
        setState(() =>
            _error = 'Проект «$name» уже существует — выберите другое имя.');
      }
      return;
    }
    if (!mounted) return;
    setState(() => _error = '');
    await widget.store.save(Project(name: name));
    final p = await widget.store.load(name);
    if (p != null) widget.onOpen(p);
    _refresh();
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('Проекты',
            style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _nameCtrl,
                decoration: const InputDecoration(
                    labelText: 'Имя проекта',
                    border: OutlineInputBorder(),
                    isDense: true),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton.icon(
                onPressed: _create,
                icon: const Icon(Icons.add),
                label: const Text('Создать')),
          ],
        ),
        if (_error.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(_error,
              style: const TextStyle(color: Colors.redAccent, fontSize: 12)),
        ],
        const SizedBox(height: 16),
        for (final name in _names)
          Card(
            child: ListTile(
              leading: const Icon(Icons.folder),
              title: Text(name),
              subtitle: Text(name == widget.current?.name
                  ? 'открыт'
                  : 'двойной клик — открыть'),
              selected: name == widget.current?.name,
              onTap: () async {
                final p = await widget.store.load(name);
                if (p != null) widget.onOpen(p);
              },
            ),
          ),
      ],
    );
  }
}
