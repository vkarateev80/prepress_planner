// Тесты монетизации в UI: bootstrap триала, статус в шапке, paywall, квота Free.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:prepress_planner/license/entitlement_store.dart';
import 'package:prepress_planner/license/license_client.dart';
import 'package:prepress_planner/license/license_controller.dart';
import 'package:prepress_planner/license/account_screen.dart';
import 'package:prepress_planner/src/projects/project.dart';
import 'package:prepress_planner/src/screens/home_shell.dart';

import 'license_account_test.dart' as acc;

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

  testWidgets('без входа чип триала открывает вход, а не биллинг',
      (tester) async {
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
    // Защита: окно биллинга без авторизации не открывается.
    expect(find.text('Препресс-Планер Pro'), findsNothing);
    expect(find.text('Аккаунт'), findsOneWidget);
    dir.deleteSync(recursive: true);
  });

  testWidgets('после входа чип открывает окно биллинга (paywall)',
      (tester) async {
    final dir = Directory.systemTemp.createTempSync('pp_ui_pay');
    final fake = acc.FakeGateway();
    final lic = LicenseController(
      store: EntitlementStore('${dir.path}/st'),
      client: LicenseClient(),
      gateway: fake,
      stateDir: '${dir.path}/st',
    );
    await tester.runAsync(() async {
      await lic.init();
      await lic.register('Владелец', 'paywall@example.com', 'secret1',
          '+79991234001');
      await lic.confirm(
          acc.FakeGateway.devEmailCode, acc.FakeGateway.devPhoneCode);
    });
    expect(lic.loggedIn, true);
    await tester.pumpWidget(MaterialApp(
      home: HomeShell(
        store: ProjectStore('${dir.path}/pr'),
        license: lic,
      ),
    ));
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.textContaining('Триал:'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Препресс-Планер Pro'), findsOneWidget);
    expect(find.text('Аккаунт'), findsNothing);
    dir.deleteSync(recursive: true);
  });

  testWidgets('форма регистрации: имя, пароль и подтверждение пароля',
      (tester) async {
    final dir = Directory.systemTemp.createTempSync('pp_regform');
    final lic = LicenseController(
      store: EntitlementStore('${dir.path}/st'),
      client: LicenseClient(),
      stateDir: '${dir.path}/st',
    );
    await tester.runAsync(() => lic.init());
    await tester.pumpWidget(MaterialApp(home: AccountScreen(license: lic)));
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tap(find.text('Нет аккаунта — зарегистрироваться'));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('Имя пользователя'), findsOneWidget);
    expect(find.text('Повторите пароль'), findsOneWidget);

    // Пустое имя → подсказка, наружу не уходим.
    await tester.enterText(find.byType(TextField).at(1), 'u@example.com');
    await tester.enterText(find.byType(TextField).at(2), '+79991234567');
    await tester.enterText(find.byType(TextField).at(3), 'secret1');
    await tester.enterText(find.byType(TextField).at(4), 'secret1');
    // Шесть полей не помещаются: прокручиваем список к кнопке.
    await tester.drag(find.byType(ListView).first, const Offset(0, -400));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(find.text('Создать аккаунт'));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('Введите имя пользователя'), findsOneWidget);

    // Пароли не совпадают.
    await tester.enterText(find.byType(TextField).at(0), 'Иван');
    await tester.enterText(find.byType(TextField).at(4), 'other');
    await tester.tap(find.text('Создать аккаунт'));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('Пароли не совпадают'), findsOneWidget);

    // Всё верно → уходим в controller (offline-фолбэк: сервера нет).
    await tester.enterText(find.byType(TextField).at(4), 'secret1');
    await tester.tap(find.text('Создать аккаунт'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.textContaining('Регистрация недоступна'), findsOneWidget);
    dir.deleteSync(recursive: true);
  });

  testWidgets('переключение вкладки: 401 → разлогин без перезагрузки',
      (tester) async {
    final dir = Directory.systemTemp.createTempSync('pp_tab401');
    final fake = acc.FakeGateway();
    final lic = LicenseController(
      store: EntitlementStore('${dir.path}/st'),
      client: LicenseClient(),
      gateway: fake,
      stateDir: '${dir.path}/st',
    );
    await tester.runAsync(() async {
      await lic.init();
      await lic.register('Тест Юзер', 'tab401@example.com', 'secret1', '+79991234567');
      await lic.confirm(
          acc.FakeGateway.devEmailCode, acc.FakeGateway.devPhoneCode);
    });
    expect(lic.loggedIn, true);

    // Другое устройство вошло — наша сессия вытеснена (сервер отвечает 401).
    fake.expiredSessions = true;
    await tester.pumpWidget(MaterialApp(
      home: HomeShell(
          store: ProjectStore('${dir.path}/pr'), license: lic),
    ));
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)));
    await tester.pump(const Duration(milliseconds: 100));
    expect(lic.loggedIn, true); // ещё не проверяли

    // Тап по вкладке → ensureSession → 401 → сброс.
    await tester.tap(find.text('Раскрой'));
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pump(const Duration(milliseconds: 100));
    expect(lic.loggedIn, false);
    expect(find.text('Войти'), findsWidgets); // AccountButton разлогинен
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
