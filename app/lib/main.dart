import 'package:flutter/material.dart';

import 'license/account_client.dart';
import 'license/entitlement_store.dart';
import 'license/license_client.dart';
import 'license/license_controller.dart';
import 'src/logs/app_log.dart';
import 'src/materials/material_library.dart';
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
  late final MaterialLibrary _materials;

  @override
  void initState() {
    super.initState();
    _license = LicenseController(
      store: EntitlementStore('state'),
      client: LicenseClient(),
      gateway: AccountGatewayHttp(), // auth + payments (VPS); офлайн-фолбэк внутри
      stateDir: 'state',
    )..init(); // bootstrap: восстановление сессии/триала
    _materials = MaterialLibrary('state')..load(); // каталог материалов
  }

  @override
  void dispose() {
    _license.dispose();
    _materials.dispose();
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
        store: ProjectStore('projects'),
        license: _license,
        materials: _materials,
      ),
    );
  }
}
