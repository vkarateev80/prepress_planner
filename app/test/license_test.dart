// Тесты лицензий в приложении: гейтинг, кэш, таймер, paywall.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:prepress_planner/license/entitlement_store.dart';
import 'package:prepress_planner/license/license_client.dart';
import 'package:prepress_planner/license/paywall_screen.dart';

void main() {
  test('feature gate: pro открывает всё, free — только базу', () {
    const proGate = FeatureGate(
        Entitlement(pro: true, until: null, trialDaysLeft: 0));
    expect(proGate.isPro, true);
    expect(proGate.allows('teo.calc'), true);
    expect(proGate.allows('reports.export'), true);

    const freeGate = FeatureGate(Entitlement.free);
    expect(freeGate.isPro, false);
    expect(freeGate.allows('project.create'), true);
    expect(freeGate.allows('layout.rect'), true);
    expect(freeGate.allows('teo.calc'), false);
    expect(freeGate.allows('reports.export'), false);
  });

  test('trial timer: остаток дней и метка', () {
    final inTrial = Entitlement(
        pro: false,
        until: DateTime.now().add(const Duration(days: 10)),
        trialDaysLeft: 10);
    final t = TrialTimer(inTrial);
    expect(t.daysLeft, 10);
    expect(t.label, contains('10'));

    final expired =
        Entitlement(pro: false, until: DateTime.now().subtract(const Duration(days: 1)));
    expect(TrialTimer(expired).daysLeft, 0);
    expect(TrialTimer(expired).label, contains('истёк'));

    const pro = Entitlement(pro: true);
    expect(const TrialTimer(pro).label, contains('Pro'));
  });

  test('entitlement store: round-trip и грэйс 30 дней', () async {
    final dir = Directory.systemTemp.createTempSync('pp_ent');
    final store = EntitlementStore(dir.path);
    await store.save(const Entitlement(
        pro: true, source: 'server'));
    final loaded = await store.load();
    expect(loaded, isNotNull);
    expect(loaded!.pro, true);

    final graceUntil =
        DateTime.now().add(const Duration(days: 10));
    final e = Entitlement(pro: true, until: graceUntil);
    expect(store.isWithinGrace(e), true);
    expect(store.isWithinGrace(
        Entitlement(pro: true, until: graceUntil),
        now: DateTime.now().add(const Duration(days: 45))),
        false);
    dir.deleteSync(recursive: true);
  });

  test('license client: офлайн-заглушка даёт триал 15 дней', () async {
    final client = LicenseClient(); // serverUrl null
    final e = await client.activate('test-machine');
    expect(e.source, 'local');
    expect(e.pro, false);
    expect(e.trialDaysLeft, 15);
    expect(e.until, isNotNull);
  });

  testWidgets('paywall: рендер и обработка кнопки', (tester) async {
    String? purchased;
    await tester.pumpWidget(MaterialApp(
      home: PaywallScreen(
        timer: TrialTimer(Entitlement(
            pro: false,
            until: DateTime.now().add(const Duration(days: 5)),
            trialDaysLeft: 5)),
        onPurchase: (p) => purchased = p,
      ),
    ));
    expect(find.textContaining('Пробный период'), findsOneWidget);
    await tester.tap(find.textContaining('Месяц'));
    await tester.pump();
    expect(purchased, 'month');
    await tester.tap(find.textContaining('Год'));
    await tester.pump();
    expect(purchased, 'year');
  });
}
