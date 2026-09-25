import 'package:flutter/material.dart';

import 'license/account_client.dart';
import 'license/entitlement_store.dart';
import 'license/license_client.dart';
import 'license/license_controller.dart';
import 'platform/env.dart';
import 'src/logs/app_log.dart';
import 'src/projects/cloud_projects.dart';
import 'src/projects/project.dart';
import 'src/screens/home_shell.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Необработанные ошибки Flutter/Dart пишутся в журнал приложения —
  // их можно посмотреть и скопировать в окне «Журнал событий».
  AppLog.instance.installGlobalHandlers();
  AppLog.instance.info('App', 'Препресс-Планер запущен.');
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
      gateway: AccountGatewayHttp(), // auth + payments (VPS); офлайн-фолбэк внутри
      stateDir: 'state',
    )..init(); // bootstrap: восстановление сессии/триала
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
      home: HomeShell(
        store: ProjectStore(
          'projects',
          // Облачный путь проектов (flutter-web-adapt, ADR-6): web-сборка
          // хранит проекты в services/api при активной сессии; desktop и
          // анонимный режим продолжают работать с локальным хранилищем.
          api: isWeb ? ProjectsApi() : null,
          tokenProvider: () async => _license.sessionToken,
        ),
        license: _license,
      ),
    );
  }
}
