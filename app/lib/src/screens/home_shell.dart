/// Оболочка приложения: навигация по вкладкам (десктоп/мобильный).
library;

import 'package:flutter/material.dart';

import '../projects/project.dart';
import 'geometry_screen.dart';
import 'layout_screen.dart';
import 'projects_screen.dart';
import 'reports_screen.dart';
import 'teo_screen.dart';

class HomeShell extends StatefulWidget {
  final ProjectStore store;
  const HomeShell({super.key, required this.store});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  Project? project;
  int _index = 0;

  void _setProject(Project p) {
    setState(() {
      project = p;
      _index = 1; // на геометрию
    });
  }

  void _update(Project p) {
    setState(() => project = p);
    widget.store.save(p); // fire-and-forget
  }

  @override
  Widget build(BuildContext context) {
    final pages = <Widget>[
      ProjectsScreen(
        store: widget.store,
        onOpen: _setProject,
        current: project,
      ),
      GeometryScreen(project: project, onChange: _update),
      LayoutScreen(project: project, onChange: _update),
      TeoScreen(project: project, onChange: _update),
      ReportsScreen(project: project, store: widget.store),
    ];
    return Scaffold(
      appBar: AppBar(
        title: Text(project == null
            ? 'Препресс-Планер'
            : '${project!.name} — Препресс-Планер'),
      ),
      body: LayoutBuilder(builder: (context, constraints) {
        final wide = constraints.maxWidth > 700;
        if (wide) {
          return Row(
            children: [
              NavigationRail(
                selectedIndex: _index,
                onDestinationSelected: (i) => setState(() => _index = i),
                labelType: NavigationRailLabelType.all,
                destinations: const [
                  NavigationRailDestination(
                      icon: Icon(Icons.folder_outlined),
                      selectedIcon: Icon(Icons.folder),
                      label: Text('Проекты')),
                  NavigationRailDestination(
                      icon: Icon(Icons.timeline),
                      label: Text('Геометрия')),
                  NavigationRailDestination(
                      icon: Icon(Icons.grid_view),
                      label: Text('Раскрой')),
                  NavigationRailDestination(
                      icon: Icon(Icons.calculate_outlined),
                      label: Text('ТЭО')),
                  NavigationRailDestination(
                      icon: Icon(Icons.description_outlined),
                      label: Text('Отчёты')),
                ],
              ),
              const VerticalDivider(width: 1),
              Expanded(child: pages[_index]),
            ],
          );
        }
        return Column(
          children: [
            Expanded(child: pages[_index]),
            NavigationBar(
              selectedIndex: _index,
              onDestinationSelected: (i) => setState(() => _index = i),
              destinations: const [
                NavigationDestination(
                    icon: Icon(Icons.folder_outlined), label: 'Проекты'),
                NavigationDestination(
                    icon: Icon(Icons.timeline), label: 'Геометрия'),
                NavigationDestination(
                    icon: Icon(Icons.grid_view), label: 'Раскрой'),
                NavigationDestination(
                    icon: Icon(Icons.calculate_outlined), label: 'ТЭО'),
                NavigationDestination(
                    icon: Icon(Icons.description_outlined), label: 'Отчёты'),
              ],
            ),
          ],
        );
      }),
    );
  }
}
