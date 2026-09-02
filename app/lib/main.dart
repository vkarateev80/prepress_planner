import 'package:flutter/material.dart';

import 'src/projects/project.dart';
import 'src/screens/home_shell.dart';

void main() {
  runApp(const PrepressPlannerApp());
}

class PrepressPlannerApp extends StatelessWidget {
  const PrepressPlannerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Препресс-Планер',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF2E5A88)),
        useMaterial3: true,
      ),
      home: HomeShell(store: ProjectStore('projects')),
    );
  }
}
