/// Экран «Проекты»: список, создание, открытие.
library;

import 'package:flutter/material.dart';

import '../projects/project.dart';

class ProjectsScreen extends StatefulWidget {
  final ProjectStore store;
  final ValueChanged<Project> onOpen;
  final Project? current;
  const ProjectsScreen(
      {super.key,
      required this.store,
      required this.onOpen,
      this.current});

  @override
  State<ProjectsScreen> createState() => _ProjectsScreenState();
}

class _ProjectsScreenState extends State<ProjectsScreen> {
  List<String> _names = [];
  final _nameCtrl = TextEditingController(text: 'Новый проект');

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
