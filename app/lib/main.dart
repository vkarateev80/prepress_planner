import 'package:flutter/material.dart';

import 'license/entitlement_store.dart';
import 'license/license_client.dart';
import 'license/license_controller.dart';
import 'src/projects/project.dart';
import 'src/screens/home_shell.dart';

void main() {
  runApp(const PrepressPlannerApp());
}

class PrepressPlannerApp extends StatefulWidget {
  const PrepressPlannerApp({super.key});

  @override
  State<PrepressPlannerApp> createState() => _PrepressPlannerAppState();
}

class _PrepressPlannerAppState extends State<PrepressPlannerApp> {
  late final LicenseController _license;

  @override
  void initState() {
    super.initState();
    _license = LicenseController(
      store: EntitlementStore('state'),
      client: LicenseClient(),
      stateDir: 'state',
    )..init(); // bootstrap триала 15 дней при первом запуске
  }

  @override
  void dispose() {
    _license.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Препресс-Планер',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF2E5A88)),
        useMaterial3: true,
      ),
      home: HomeShell(store: ProjectStore('projects'), license: _license),
    );
  }
}
