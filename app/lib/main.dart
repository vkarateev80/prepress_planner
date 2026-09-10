import 'package:flutter/material.dart';

import 'license/account_client.dart';
import 'license/entitlement_store.dart';
import 'license/license_client.dart';
import 'license/license_controller.dart';
import 'platform/app_dirs.dart';
import 'src/logs/app_log.dart';
import 'src/materials/material_library.dart';
import 'src/projects/project.dart';
import 'src/screens/home_shell.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Необработанные ошибки Flutter/Dart пишутся в журнал приложения —
  // их можно посмотреть и скопировать в окне «Журнал событий».
  AppLog.instance.installGlobalHandlers();
  AppLog.instance.info('App', 'Препресс-Планер запущен.');
  // На Android/iOS рабочий каталог процесса недоступен для записи, поэтому
  // состояние/проекты живут в каталоге приложения; на desktop/web функция
  // возвращает null и пути остаются прежними относительными ('state',
  // 'projects') — поведение существующих сборок не меняется.
  final dataDir = await mobileDataDir();
  runApp(PrepressPlannerApp(dataDir: dataDir));
}

class PrepressPlannerApp extends StatefulWidget {
  /// Каталог данных приложения (Android/iOS) либо null на desktop/web —
  /// тогда каталоги состояния/проектов задаются относительными путями.
  final String? dataDir;

  const PrepressPlannerApp({super.key, this.dataDir});

  @override
  State<PrepressPlannerApp> createState() => _PrepressPlannerAppState();
}

class _PrepressPlannerAppState extends State<PrepressPlannerApp> {
  late final LicenseController _license;
  late final MaterialLibrary _materials;

  /// Каталог лицензии/материалов: на desktop/web — прежний относительный
  /// 'state', на мобильных — внутри каталога приложения.
  String get _stateDir =>
      widget.dataDir == null ? 'state' : '${widget.dataDir}/state';

  /// Каталог проектов: на desktop/web — прежний относительный 'projects'.
  String get _projectsDir =>
      widget.dataDir == null ? 'projects' : '${widget.dataDir}/projects';

  @override
  void initState() {
    super.initState();
    _license = LicenseController(
      store: EntitlementStore(_stateDir),
      client: LicenseClient(),
      gateway: AccountGatewayHttp(), // auth + payments (VPS); офлайн-фолбэк внутри
      stateDir: _stateDir,
    )..init(); // bootstrap: восстановление сессии/триала
    _materials = MaterialLibrary(_stateDir)..load(); // каталог материалов
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
        store: ProjectStore(_projectsDir),
        license: _license,
        materials: _materials,
      ),
    );
  }
}
