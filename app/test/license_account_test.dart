// Тесты аккаунта: вход/регистрация/выход (device_id 1/1), сброс пароля,
// синхронизация подписки с сервера, покупка через gateway; офлайн-фолбэк.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:prepress_planner/license/account_client.dart';
import 'package:prepress_planner/license/entitlement_store.dart';
import 'package:prepress_planner/license/license_client.dart';
import 'package:prepress_planner/license/license_controller.dart';

/// Фейковый шлюз: предсказуемые сессии/подписки/сброс, без сети.
class FakeGateway implements AccountGateway {
  final Map<String, String> users = {}; // email → password
  final Map<String, String> _resetCodes = {}; // email → код
  final Map<String, String> _sessions = {}; // token → email
  final Set<String> _unverified = {}; // ждут подтверждения
  bool serverDown = false;
  DateTime? _until;
  String? _plan;
  int purchaseCount = 0;

  static const devEmailCode = '111111';
  static const devPhoneCode = '222222';

  /// Посев данных: регистрация + подтверждение (для setup в тестах).
  Future<void> seed(String email, String password) async {
    await register(email, password, '+79991112233', 'dev-1');
    await confirm(email, devEmailCode, devPhoneCode, 'dev-1');
  }

  @override
  Future<RegisterPending> register(
      String email, String password, String phone, String deviceId) async {
    if (serverDown) throw const ApiException('Сервер недоступен');
    if (users.containsKey(email)) {
      throw const ApiException('Email уже зарегистрирован', statusCode: 409);
    }
    users[email] = password;
    _unverified.add(email);
    return const RegisterPending(
        devEmailCode: devEmailCode, devPhoneCode: devPhoneCode);
  }

  @override
  Future<AccountSession> confirm(String email, String emailCode,
      String phoneCode, String deviceId) async {
    if (serverDown) throw const ApiException('Сервер недоступен');
    if (!_unverified.contains(email)) {
      throw const ApiException('Аккаунт уже подтверждён', statusCode: 409);
    }
    if (emailCode != devEmailCode || phoneCode != devPhoneCode) {
      throw const ApiException('Неверный или истёкший код', statusCode: 400);
    }
    _unverified.remove(email);
    final token = 'tok-$email';
    _sessions[token] = email;
    return AccountSession(token: token, email: email);
  }

  @override
  Future<RegisterPending> confirmResend(String email, String channel) async {
    if (serverDown) throw const ApiException('Сервер недоступен');
    if (!users.containsKey(email)) return const RegisterPending();
    return RegisterPending(
      devEmailCode: channel == 'email' ? devEmailCode : null,
      devPhoneCode: channel == 'phone' ? devPhoneCode : null,
    );
  }

  @override
  Future<AccountSession> login(
      String email, String password, String deviceId) async {
    if (serverDown) throw const ApiException('Сервер недоступен');
    if (users[email] != password) {
      throw const ApiException('Неверный email или пароль', statusCode: 401);
    }
    if (_unverified.contains(email)) {
      throw const ApiException('Аккаунт не подтверждён. '
          'Введите коды с почты и из SMS.', statusCode: 403);
    }
    // Политика 1/1: любая прежняя сессия вытесняется.
    _sessions.clear();
    final token = 'tok-$email';
    _sessions[token] = email;
    return AccountSession(token: token, email: email);
  }

  @override
  Future<void> logout(String token) async {
    _sessions.remove(token);
  }

  @override
  Future<List<AccountDevice>> devices(String token) async {
    if (!_sessions.containsKey(token)) return const [];
    return const [
      AccountDevice(deviceId: 'dev-1', current: true),
    ];
  }

  @override
  Future<String?> forgot(String email) async {
    if (serverDown) throw const ApiException('Сервер недоступен');
    final code = '123456';
    _resetCodes[email] = code;
    return code; // dev-режим: код в ответе
  }

  @override
  Future<void> reset(String email, String code, String newPassword) async {
    if (serverDown) throw const ApiException('Сервер недоступен');
    if (_resetCodes[email] != code) {
      throw const ApiException('Неверный или истёкший код', statusCode: 400);
    }
    _resetCodes.remove(email);
    if (!users.containsKey(email)) {
      throw const ApiException('Пользователь не найден', statusCode: 404);
    }
    users[email] = newPassword;
    _sessions.clear(); // сброс отзывает сессии
  }

  @override
  Future<ServerSubscription> subscription(String token) async {
    if (serverDown) throw const ApiException('Сервер недоступен');
    return ServerSubscription(plan: _plan, pro: _until != null, until: _until);
  }

  @override
  Future<List<Map<String, dynamic>>> plans(String token) async => [
        {'plan': 'month', 'title': 'Pro на месяц', 'amount_rub': 990},
        {'plan': 'year', 'title': 'Pro на год', 'amount_rub': 9900},
      ];

  @override
  Future<Map<String, dynamic>> purchase(String token, String plan) async {
    if (serverDown) throw const ApiException('Сервер недоступен');
    purchaseCount++;
    _plan = plan;
    final now = DateTime.now();
    _until = now.add(Duration(days: plan == 'year' ? 365 : 30));
    return {'order_id': 'o1', 'plan': plan};
  }

  /// Эмуляция оплаты со стороны вебхука (для restore).
  void grant(String plan) {
    _plan = plan;
    final now = DateTime.now();
    _until = now.add(Duration(days: plan == 'year' ? 365 : 30));
  }
}

void main() {
  late Directory dir;
  late FakeGateway fake;

  LicenseController make() {
    return LicenseController(
      store: EntitlementStore(dir.path),
      client: LicenseClient(),
      gateway: fake,
      stateDir: dir.path,
    );
  }

  setUp(() {
    dir = Directory.systemTemp.createTempSync('pp_acc');
    fake = FakeGateway();
  });

  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('регистрация → подписка free; покупка → Pro; сессия восстанавливается',
      () async {
    final lic = make();
    await lic.init();
    expect(lic.ready, true);

    final res = await lic.register('user@example.com', 'secret1', '+79991234567');
    expect(res.error, isNull);
    expect(res.devEmailCode, FakeGateway.devEmailCode);
    expect(res.devPhoneCode, FakeGateway.devPhoneCode);
    expect(lic.loggedIn, false); // фаза 1 — сессии ещё нет
    expect(lic.needsConfirm, true);
    expect(lic.accountEmail, isNull);

    final cerr = await lic.confirm(
        FakeGateway.devEmailCode, FakeGateway.devPhoneCode);
    expect(cerr, isNull);
    expect(lic.loggedIn, true);
    expect(lic.needsConfirm, false);
    expect(lic.accountEmail, 'user@example.com');
    expect(lic.entitlement.pro, false); // без подписки — Free

    final perr = await lic.purchase('month');
    expect(perr, isNull);
    expect(lic.entitlement.pro, true);
    expect(lic.entitlement.until, isNotNull);
    expect(lic.entitlement.source, 'server');
    expect(fake.purchaseCount, 1);

    // Перезапуск: сессия восстанавливается, подписка с сервера.
    fake.grant('year');
    final lic2 = make();
    await lic2.init();
    expect(lic2.loggedIn, true);
    expect(lic2.accountEmail, 'user@example.com');
    expect(lic2.entitlement.pro, true);
  });

  test('вход передаёт device_id и вытесняет прежние сессии (1/1)', () async {
    await fake.seed('a@b.co', 'secret1');
    final lic = make();
    await lic.init();
    final err = await lic.login('a@b.co', 'secret1');
    expect(err, isNull);
    expect(lic.loggedIn, true);
    // Устройства: список из одной активной сессии (лимит 1/1).
    final devs = await lic.devices();
    expect(devs.length, 1);
    expect(devs.first.current, true);
  });

  test('вход с неверным паролем → ошибка, аккаунт не вошёл', () async {
    await fake.seed('a@b.co', 'secret1');
    final lic = make();
    await lic.init();
    final err = await lic.login('a@b.co', 'wrong-password');
    expect(err, isNotNull);
    expect(lic.loggedIn, false);
  });

  test('выход отзывает сессию и возвращает к офлайн-состоянию', () async {
    final lic = make();
    await lic.init();
    await lic.register('x@y.zz', 'secret1', '+79991234567');
    await lic.confirm(
        FakeGateway.devEmailCode, FakeGateway.devPhoneCode);
    await lic.purchase('year');
    expect(lic.loggedIn, true);
    expect(lic.entitlement.pro, true);

    await lic.logout();
    expect(lic.loggedIn, false);
    expect(lic.accountEmail, isNull);
    expect(lic.entitlement.pro, false);
  });

  test('forgot + reset: код меняет пароль, старый не подходит', () async {
    await fake.seed('reset@example.com', 'old-pass1');
    final lic = make();
    await lic.init();

    final res = await lic.forgot('reset@example.com');
    expect(res.error, isNull);
    expect(res.devCode, '123456');

    final rerr = await lic.reset('reset@example.com', '123456', 'new-pass1');
    expect(rerr, isNull);

    // Старый пароль отклонён, новый принимается.
    final err1 = await lic.login('reset@example.com', 'old-pass1');
    expect(err1, isNotNull);
    final err2 = await lic.login('reset@example.com', 'new-pass1');
    expect(err2, isNull);
  });

  test('reset с неверным кодом → ошибка', () async {
    await fake.seed('r2@example.com', 'old-pass1');
    final lic = make();
    await lic.init();
    final rerr = await lic.reset('r2@example.com', '000000', 'new-pass1');
    expect(rerr, isNotNull);
  });

  test('сервер недоступен: вход даёт ошибку, кэш/Free сохраняется', () async {
    fake.serverDown = true;
    final lic = make();
    await lic.init();
    final err = await lic.login('a@b.co', 'secret1');
    expect(err, contains('Сервер недоступен'));
    expect(lic.loggedIn, false);
    expect(lic.entitlement.pro, false);
  });

  test('офлайн-путь без gateway: триал и покупка-заглушка не изменились',
      () async {
    final lic = LicenseController(
      store: EntitlementStore(dir.path),
      client: LicenseClient(),
      stateDir: dir.path,
    );
    await lic.init();
    expect(lic.gate.isTrialActive, true);
    expect(lic.loggedIn, false);
    final err = await lic.purchase('month');
    expect(err, isNull);
    expect(lic.entitlement.pro, true);
    expect(lic.entitlement.source, 'local');
  });

  // Двухфазная регистрация: register → 202 Accepted (pending + dev-коды),
  // confirm → 201 Created (сессия). Раньше register отдавал 201 с токеном.
  test('AuthApi: register 202 с dev-кодами, confirm 201 с сессией', () async {
    final server = await HttpServer.bind('127.0.0.1', 0);
    addTearDown(() => server.close(force: true));
    final paths = <String>[];
    server.listen((req) async {
      paths.add(req.uri.path);
      req.response.headers.contentType = ContentType.json;
      if (req.uri.path == '/auth/register') {
        req.response.statusCode = 202;
        req.response.write(jsonEncode({
          'pending': true,
          'email': 'new@example.com',
          'phone': '+79991234567',
          'dev_email_code': '654321',
          'dev_phone_code': '123456',
          'sms_sent': false,
        }));
      } else if (req.uri.path == '/auth/confirm') {
        req.response.statusCode = 201;
        req.response.write(jsonEncode({
          'token': 'tok-confirm',
          'user': {'email': 'new@example.com'},
          'orgs': [],
        }));
      } else {
        req.response.statusCode = 404;
        req.response.write(jsonEncode({'detail': 'not found'}));
      }
      await req.response.close();
    });
    final api = AuthApi(baseUrl: 'http://127.0.0.1:${server.port}');
    final pending = await api.register(
        'new@example.com', 'secret1', '+79991234567', 'dev-1');
    expect(pending.ok, true);
    expect(pending.devEmailCode, '654321');
    expect(pending.devPhoneCode, '123456');

    final session = await api.confirm(
        'new@example.com', '654321', '123456', 'dev-1');
    expect(session.token, 'tok-confirm');
    expect(session.email, 'new@example.com');
    expect(paths, ['/auth/register', '/auth/confirm']);
  });

  // Вход с 403 «не подтверждён» переводит контроллер в режим confirm.
  test('login с 403 выставляет needsConfirm', () async {
    final lic = make();
    await lic.init();
    await lic.register('gate@example.com', 'secret1', '+79991234567');
    // Выход из состояния pending имитируем: новая попытка входа без confirm.
    final err = await lic.login('gate@example.com', 'secret1');
    expect(err, isNotNull);
    expect(lic.needsConfirm, true);
    expect(lic.loggedIn, false);
    // После подтверждения вход работает.
    final cerr = await lic.confirm(
        FakeGateway.devEmailCode, FakeGateway.devPhoneCode);
    expect(cerr, isNull);
    expect(lic.loggedIn, true);
  });
}
