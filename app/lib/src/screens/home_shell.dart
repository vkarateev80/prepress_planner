/// Оболочка приложения: навигация по вкладкам (десктоп/мобильный).
library;

import 'package:flutter/material.dart';

import '../../license/license_controller.dart';
import '../../license/paywall_screen.dart';
import '../../license/account_screen.dart';
import '../../platform/open_url.dart';
import '../converter/api_converter.dart';
import '../converter/converter_api.dart';
import '../logs/app_log.dart';
import '../projects/project.dart';
import '../widgets/log_window.dart';
import 'geometry_screen.dart';
import 'layout_screen.dart';
import 'projects_screen.dart';
import 'reports_screen.dart';
import 'teo_screen.dart';

class HomeShell extends StatefulWidget {
  final ProjectStore store;
  final LicenseController? license;
  const HomeShell({super.key, required this.store, this.license});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell>
    with WidgetsBindingObserver {
  Project? project;
  int _index = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.license?.addListener(_onLicense);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.license?.removeListener(_onLicense);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Возврат в окно/вкладку → сразу проверяем сессию (1/1): вытеснение
    // с другого устройства откатывает аккаунт без видимого «лага».
    if (state == AppLifecycleState.resumed) {
      widget.license?.ensureSession();
    }
  }

  void _onLicense() {
    if (mounted) setState(() {});
  }

  void _setProject(Project p) {
    widget.license?.ensureSession(); // 401 → разлогин (1/1), fire-and-forget
    setState(() {
      project = p;
      _index = 1; // на геометрию
    });
  }

  void _update(Project p) {
    setState(() => project = p);
    widget.store.save(p); // fire-and-forget
  }

  /// Pro-вкладки (всё, кроме «Проекты»).
  static bool _isProTab(int i) => i == 1 || i == 3 || i == 4;

  bool _tabAllowed(int i) {
    final lic = widget.license;
    if (lic == null) return true;
    if (_isProTab(i) && !lic.gate.hasProAccess) return false;
    return true;
  }

  void _selectTab(int i) {
    // Любое переключение вкладки проверяет сессию: вытеснение (1/1)
    // откатывает аккаунт сразу, не дожидаясь перезагрузки страницы.
    widget.license?.ensureSession();
    if (!_tabAllowed(i)) {
      final lic = widget.license;
      if (lic != null) {
        showProSheet(context, lic,
            feature: 'Эта функция доступна в Pro');
      }
      return;
    }
    setState(() => _index = i);
  }

  void _requirePro(String feature) {
    final lic = widget.license;
    if (lic == null || lic.gate.hasProAccess) return;
    showProSheet(context, lic, feature: feature);
  }

  /// Конвертер закрытых форматов для текущего окружения:
  /// * web-сборка + `services/api` в store → путь через api (ADR-7):
  ///   multipart-загрузка с `convert=svg` и скачание `/files/{id}/content`;
  ///   при отсутствии сессии/облачного проекта — фолбэк на прямой
  ///   `services/converter` (`/convert` через edge nginx);
  /// * desktop (api не подключён) → null, GeometryScreen использует
  ///   прежний `ConverterApi` (поведение не меняется).
  Converter? _closedConverter() {
    final api = widget.store.api;
    if (api == null) return null;
    return ApiConverter(
      api: api,
      tokenProvider: () async => widget.license?.sessionToken,
      projectIdProvider: () async {
        final p = project;
        if (p == null) return null;
        return widget.store.ensureCloudId(p);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final pages = <Widget>[
      ProjectsScreen(
        store: widget.store,
        onOpen: _setProject,
        current: project,
        gate: widget.license?.gate,
        onNeedPro: () => _requirePro(
            'Второй проект доступен в Pro (Free — 1 проект)'),
      ),
      GeometryScreen(
        project: project,
        onChange: _update,
        converter: _closedConverter(),
        store: widget.store,
      ),
      LayoutScreen(
        project: project,
        onChange: _update,
        gate: widget.license?.gate,
        onNeedPro: () =>
            _requirePro('Перебор вариантов раскроя доступен в Pro'),
      ),
      TeoScreen(project: project, onChange: _update),
      ReportsScreen(project: project, store: widget.store),
    ];

    // Футер: юр. информация открывается по копирайту (отдельная ссылка
    // и вкладка убраны по решению владельца).
    Widget footer(BuildContext context) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(
                alpha: 0.4,
              ),
          border: Border(
            top: BorderSide(
              color: Theme.of(context).colorScheme.outlineVariant.withValues(
                    alpha: 0.3,
                  ),
              width: 0.5,
            ),
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            TextButton(
              onPressed: () {
                // Web: открыть в новой вкладке; desktop: системный браузер.
                openUrlExternal('https://prepressplan.ru/legal');
              },
              style: TextButton.styleFrom(
                foregroundColor:
                    Theme.of(context).colorScheme.onSurfaceVariant,
              ),
              child: Text(
                '\u00A9 ${DateTime.now().year} Препресс-Планер',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ],
        ),
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: Text(project == null
            ? 'Препресс-Планер'
            : '${project!.name} — Препресс-Планер'),
        actions: [
          // Журнал событий — доступен с любой вкладки; бейдж показывает
          // число ошибок (уровень E) с момента последней очистки.
          ListenableBuilder(
            listenable: AppLog.instance,
            builder: (context, _) {
              final errors = AppLog.instance.errorCount;
              return IconButton(
                tooltip: 'Журнал событий (ошибки можно копировать)',
                icon: Badge(
                  isLabelVisible: errors > 0,
                  label: Text('$errors'),
                  child: const Icon(Icons.receipt_long_outlined),
                ),
                onPressed: () => showLogWindow(context),
              );
            }),
          if (widget.license != null) ...[
            AccountButton(license: widget.license!),
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: _StatusChip(license: widget.license!),
            ),
          ],
        ],
      ),
      body: LayoutBuilder(builder: (context, constraints) {
        final wide = constraints.maxWidth > 700;
        if (wide) {
          return Column(
            children: [
              Expanded(
                child: Row(
                  children: [
                    NavigationRail(
                      selectedIndex: _index,
                      onDestinationSelected: _selectTab,
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
                ),
              ),
              footer(context),
            ],
          );
        }
        return Column(
          children: [
            Expanded(child: pages[_index]),
            footer(context),
            NavigationBar(
              selectedIndex: _index,
              onDestinationSelected: _selectTab,
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

/// Чип статуса подписки в шапке: открывает paywall.
class _StatusChip extends StatelessWidget {
  final LicenseController license;
  const _StatusChip({required this.license});

  @override
  Widget build(BuildContext context) {
    final isPro = license.entitlement.pro;
    final icon = isPro
        ? Icons.workspace_premium
        : (license.gate.isTrialActive
            ? Icons.timer_outlined
            : Icons.lock_outline);
    return TextButton.icon(
      onPressed: () => openPaywall(context, license),
      icon: Icon(icon, size: 18),
      label: Text(license.statusLabel),
      style: TextButton.styleFrom(
        foregroundColor: isPro
            ? Theme.of(context).colorScheme.primary
            : null,
      ),
    );
  }
}
