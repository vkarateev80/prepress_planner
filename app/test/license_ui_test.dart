// Тесты монетизации в UI: bootstrap триала, статус в шапке, paywall, квота Free.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:prepress_planner/license/entitlement_store.dart';
import 'package:prepress_planner/license/license_client.dart';
import 'package:prepress_planner/license/license_controller.dart';
import 'package:prepress_planner/src/projects/project.dart';
import 'package:prepress_planner/src/screens/home_shell.dart';

void main() {
  test('bootstrap: первый запуск → триал 15 дней; триал = полный доступ', () async {
    final dir = Directory.systemTemp.createTempSync('pp_boot');
    final lic = LicenseController(
      store: EntitlementStore(dir.path),
      client: LicenseClient(),
      stateDir: dir.path,
    );
    await lic.init();
    expect(lic.ready, true);
    expect(lic.entitlement.source, 'local');
    expect(lic.entitlement.pro, false);
    expect(lic.gate.isTrialActive, true);
    // Триал открывает Pro-возможности.
    expect(lic.gate.allows('teo.calc'), true);
    expect(lic.gate.allows('reports.export'), true);
    expect(lic.statusLabel, startsWith('Триал:'));
    // Повторный запуск не пересоздаёт триал (кэш).
    final lic2 = LicenseController(
      store: EntitlementStore(dir.path),
      client: LicenseClient(),
      stateDir: dir.path,
    );
    await lic2.init();
    expect(lic2.entitlement.source, 'local');
    dir.deleteSync(recursive: true);
  });

  test('purchase: месяц → Pro, кэш обновлён', () async {
    final dir = Directory.systemTemp.createTempSync('pp_pur');
    final lic = LicenseController(
      store: EntitlementStore(dir.path),
      client: LicenseClient(),
      stateDir: dir.path,
    );
    await lic.init();
    await lic.purchase('month');
    expect(lic.entitlement.pro, true);
    expect(lic.entitlement.until, isNotNull);
    expect(lic.statusLabel, 'Pro');
    expect(lic.timer.label, contains('Pro'));
    final cached = await lic.store.load();
    expect(cached!.pro, true);
    dir.deleteSync(recursive: true);
  });

  test('free (триал истёк): только база, квота 1 проект', () async {
    final dir = Directory.systemTemp.createTempSync('pp_free');
    final store = EntitlementStore(dir.path);
    await store.save(Entitlement(
        pro: false,
        until: DateTime.now().subtract(const Duration(days: 1)),
        trialDaysLeft: 0));
    final lic = LicenseController(
      store: store,
      client: LicenseClient(),
      stateDir: dir.path,
    );
    await lic.init();
    expect(lic.gate.isTrialActive, false);
    expect(lic.gate.hasProAccess, false);
    expect(lic.gate.allows('project.create'), true);
    expect(lic.gate.allows('layout.rect'), true);
    expect(lic.gate.allows('teo.calc'), false);
    expect(lic.statusLabel, 'Free');
    dir.deleteSync(recursive: true);
  });

  testWidgets('шапка: чип триала; тап открывает paywall', (tester) async {
    final dir = Directory.systemTemp.createTempSync('pp_ui');
    final lic = LicenseController(
      store: EntitlementStore('${dir.path}/st'),
      client: LicenseClient(),
      stateDir: '${dir.path}/st',
    );
    await tester.runAsync(() => lic.init());
    await tester.pumpWidget(MaterialApp(
      home: HomeShell(
        store: ProjectStore('${dir.path}/pr'),
        license: lic,
      ),
    ));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.textContaining('Триал:'), findsOneWidget);
    await tester.tap(find.textContaining('Триал:'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Препресс-Планер Pro'), findsOneWidget);
    dir.deleteSync(recursive: true);
  });

  testWidgets('free-квота: второй проект → шторка «Оформить Pro»', (tester) async {
    final dir = Directory.systemTemp.createTempSync('pp_quota');
    final pstore = ProjectStore('${dir.path}/pr');
    await tester.runAsync(() async {
      await pstore.save(Project(name: 'Первый'));
      await EntitlementStore('${dir.path}/st').save(Entitlement(
          pro: false,
          until: DateTime.now().subtract(const Duration(days: 1)),
          trialDaysLeft: 0));
    });
    final lic = LicenseController(
      store: EntitlementStore('${dir.path}/st'),
      client: LicenseClient(),
      stateDir: '${dir.path}/st',
    );
    await tester.runAsync(() => lic.init());
    expect(lic.gate.hasProAccess, false);
    await tester.pumpWidget(MaterialApp(
      home: HomeShell(store: pstore, license: lic),
    ));
    // Даём реальному IO (список проектов) завершиться вне fakeAsync.
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Первый'), findsOneWidget);
    await tester.tap(find.text('Создать'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Оформить Pro'), findsOneWidget);
    expect(find.textContaining('доступен в Pro'), findsWidgets);
    // Проект не создан: в хранилище по-прежнему один файл.
    final files = Directory('${dir.path}/pr')
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.json'))
        .length;
    expect(files, 1);
    dir.deleteSync(recursive: true);
  });
}
