/// Контроллер лицензии/аккаунта в приложении.
///
/// Режимы:
/// - без [AccountGateway] — офлайн: локальный триал 15 дней, покупка-заглушка
///   (текущее поведение, используется в тестах и без сети);
/// - с [AccountGateway] — аккаунт email+пароль: вход/регистрация/выход,
///   подписка приходит с микросервиса оплаты (payments), покупка — заказ +
///   тестовое подтверждение. Если сервер недоступен, работает офлайн-фолбэк
///   (кэш или локальный триал).
library;

import 'package:flutter/foundation.dart';

import 'account_client.dart';
import 'entitlement_store.dart';
import 'license_client.dart';

/// Связывает хранилище (кэш), шлюз аккаунта (auth+payments, опционально),
/// [MachineId] и уведомляет UI об изменениях.
class LicenseController extends ChangeNotifier {
  final EntitlementStore store;
  final LicenseClient client;
  final String stateDir; // каталог для machine_id.txt и session.json
  final AccountGateway? gateway;
  final SessionStore sessionStore;

  Entitlement _entitlement = Entitlement.free;
  AccountSession? _session;
  bool _ready = false;
  bool _busy = false;
  String? _accountError;

  LicenseController({
    required this.store,
    required this.client,
    required this.stateDir,
    this.gateway,
  }) : sessionStore = SessionStore(stateDir);

  Entitlement get entitlement => _entitlement;
  bool get ready => _ready;
  bool get busy => _busy;
  String? get accountError => _accountError;
  FeatureGate get gate => FeatureGate(_entitlement);
  TrialTimer get timer => TrialTimer(_entitlement);

  /// Вошёл ли пользователь (есть сохранённая сессия).
  bool get loggedIn => _session != null;
  String? get accountEmail => _session?.email;

  /// Email в процессе подтверждения регистрации (двухфазная регистрация):
  /// не null после register (фаза 1) или после входа с 403 «не подтверждён».
  String? _pendingEmail;
  String? get pendingEmail => _pendingEmail;
  bool get needsConfirm => _pendingEmail != null;

  /// Bearer-токен сессии (для облачных вызовов, например `/api/projects`).
  String? get sessionToken => _session?.token;

  /// Идентификатор этого устройства (machine_id) — device_id сессии.
  String? _deviceId;

  Future<String> _deviceIdOrError() async {
    final d = _deviceId;
    if (d != null && d.isNotEmpty) return d;
    final machine = await MachineId.load(stateDir);
    _deviceId = machine;
    return machine;
  }

  /// Первый запуск: кэш → восстановление сессии → сервер; без кэша и сессии
  /// активируем офлайн-триал 15 дней.
  Future<void> init() async {
    await _deviceIdOrError();
    final session = await sessionStore.load();
    _session = session;
    final cached = await store.load();
    // Серверный кэш значим только при живой сессии (иначе это чужой Pro).
    final usableCache = (cached != null &&
            (cached.source != 'server' || session != null))
        ? cached
        : null;
    if (usableCache != null) {
      _entitlement = usableCache;
    }
    if (session != null && gateway != null) {
      // Есть сессия — пытаемся получить актуальную подписку с сервера.
      await _refreshFromServer(quiet: true);
    } else if (_entitlement.source == 'local' &&
        _entitlement.pro == false &&
        _entitlement.until == null) {
      // Нет кэша вовсе — локальный триал (или свободный доступ без сети).
      final machineId = await MachineId.load(stateDir);
      final e = await client.activate(machineId);
      _entitlement = e;
      await store.save(e);
    }
    _ready = true;
    notifyListeners();
  }

  Future<void> _refreshFromServer({bool quiet = false}) async {
    final g = gateway;
    final s = _session;
    if (g == null || s == null) return;
    try {
      final sub = await g.subscription(s.token);
      if (sub.pro && sub.until != null) {
        _entitlement = Entitlement(
          pro: true,
          until: sub.until,
          trialDaysLeft: 0,
          source: 'server',
        );
        await store.save(_entitlement);
      } else if (!quiet) {
        // Свободный аккаунт: сервер подписки не имеет — показываем Free,
        // но офлайн-кэш (триал) не затираем.
        if (_entitlement.source == 'server' ||
            (!_entitlement.pro && _entitlement.until == null)) {
          _entitlement = Entitlement.free;
        }
      }
      _accountError = null;
    } on ApiException catch (e) {
      if (e.statusCode == 401) {
        // Сессия вытеснена/отозвана на сервере (политика 1/1) —
        // сбрасываем локальную сессию, чтобы UI не показывал вход.
        await _dropSession();
      } else if (!quiet) {
        _accountError = e.toString();
      }
    } on Exception catch (e) {
      // Сервер недоступен — офлайн-фолбэк (кэш/триал) остаётся.
      if (!quiet) _accountError = e.toString();
    }
    notifyListeners();
  }

  /// Сброс локальной сессии при 401 (вытеснение/отзыв): кэш подписки
  /// остаётся только если он локальный (триал), иначе — Free (как logout).
  Future<void> _dropSession() async {
    _session = null;
    await sessionStore.clear();
    final cached = await store.load();
    final offline = (cached != null && cached.source == 'local')
        ? cached
        : Entitlement.free;
    _entitlement = offline;
    _accountError = null;
  }

  /// Вход в аккаунт (с этого устройства; лимит 1/1 — прежняя сессия
  /// на другом устройстве будет вытеснена сервером).
  /// 403 «не подтверждён» переводит контроллер в режим ожидания кодов
  /// ([needsConfirm] → true).
  Future<String?> login(String email, String password) async {
    final g = gateway;
    if (g == null) return 'Вход недоступен: сервер не настроен';
    _busy = true;
    _accountError = null;
    notifyListeners();
    try {
      final deviceId = await _deviceIdOrError();
      final session = await g.login(email.trim(), password, deviceId);
      _session = session;
      _pendingEmail = null;
      await sessionStore.save(session);
      await _refreshFromServer();
      return null;
    } on ApiException catch (e) {
      if (e.statusCode == 403) _pendingEmail = email.trim();
      _accountError = e.toString();
      return e.toString();
    } on Exception catch (e) {
      _accountError = e.toString();
      return e.toString();
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  /// Регистрация, фаза 1: аккаунт создан, коды отправлены; сессии нет.
  /// Успех → [needsConfirm] = true, в ответе dev-коды недоступных каналов.
  Future<({String? error, String? devEmailCode, String? devPhoneCode})>
      register(String email, String password, String phone) async {
    final g = gateway;
    if (g == null) {
      return (
        error: 'Регистрация недоступна: сервер не настроен',
        devEmailCode: null,
        devPhoneCode: null,
      );
    }
    _busy = true;
    _accountError = null;
    notifyListeners();
    try {
      final deviceId = await _deviceIdOrError();
      final res =
          await g.register(email.trim(), password, phone.trim(), deviceId);
      _pendingEmail = res.ok ? email.trim() : null;
      return (
        error: res.error,
        devEmailCode: res.devEmailCode,
        devPhoneCode: res.devPhoneCode,
      );
    } on ApiException catch (e) {
      _accountError = e.toString();
      return (error: e.toString(), devEmailCode: null, devPhoneCode: null);
    } on Exception catch (e) {
      _accountError = e.toString();
      return (error: e.toString(), devEmailCode: null, devPhoneCode: null);
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  /// Регистрация, фаза 2: оба кода → сессия.
  Future<String?> confirm(String emailCode, String phoneCode) async {
    final g = gateway;
    final email = _pendingEmail;
    if (g == null || email == null) {
      return 'Подтверждение недоступно: нет ожидающей регистрации';
    }
    _busy = true;
    _accountError = null;
    notifyListeners();
    try {
      final deviceId = await _deviceIdOrError();
      final session = await g.confirm(
          email, emailCode.trim(), phoneCode.trim(), deviceId);
      _session = session;
      _pendingEmail = null;
      await sessionStore.save(session);
      await _refreshFromServer();
      return null;
    } on Exception catch (e) {
      _accountError = e.toString();
      return e.toString();
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  /// Переотправка кода подтверждения (channel: email | phone).
  Future<({String? error, String? devEmailCode, String? devPhoneCode})>
      resendConfirm(String channel) async {
    final g = gateway;
    final email = _pendingEmail;
    if (g == null || email == null) {
      return (
        error: 'Переотправка недоступна: нет ожидающей регистрации',
        devEmailCode: null,
        devPhoneCode: null,
      );
    }
    try {
      final res = await g.confirmResend(email, channel);
      return (
        error: res.error,
        devEmailCode: res.devEmailCode,
        devPhoneCode: res.devPhoneCode,
      );
    } on Exception catch (e) {
      return (error: e.toString(), devEmailCode: null, devPhoneCode: null);
    }
  }

  /// Отмена ожидания подтверждения (кнопка «Назад ко входу»).
  void cancelConfirm() {
    _pendingEmail = null;
    notifyListeners();
  }

  /// Запросить код сброса пароля. Возвращает dev_code (если почта не
  /// настроена — код придёт в ответе) либо null (код ушёл на email).
  Future<({String? error, String? devCode})> forgot(String email) async {
    final g = gateway;
    if (g == null) {
      return (error: 'Сброс недоступен: сервер не настроен', devCode: null);
    }
    try {
      final code = await g.forgot(email.trim());
      return (error: null, devCode: code);
    } on Exception catch (e) {
      return (error: e.toString(), devCode: null);
    }
  }

  /// Сбросить пароль по коду.
  Future<String?> reset(String email, String code, String newPassword) async {
    final g = gateway;
    if (g == null) return 'Сброс недоступен: сервер не настроен';
    try {
      await g.reset(email.trim(), code.trim(), newPassword);
      return null;
    } on Exception catch (e) {
      return e.toString();
    }
  }

  /// Проверка живости сессии (политика 1/1): вызывается при переключении
  /// вкладок; сервер 401 → локальная сессия сбрасывается сразу, без
  /// перезагрузки. Сетевые ошибки игнорируются (офлайн не разлогинивает).
  Future<void> ensureSession() async {
    final g = gateway;
    final s = _session;
    if (g == null || s == null) return;
    try {
      await g.me(s.token);
    } on ApiException catch (e) {
      if (e.statusCode == 401) {
        await _dropSession();
        notifyListeners();
      }
    } on Exception {
      // Сервер недоступен — сессию не трогаем.
    }
  }

  /// Активные устройства аккаунта (политика 1/1 — обычно одна).
  Future<List<AccountDevice>> devices() async {
    final g = gateway;
    final s = _session;
    if (g == null || s == null) return const [];
    try {
      return await g.devices(s.token);
    } on ApiException catch (e) {
      // 401 — сессию вытеснили, пока приложение было открыто.
      if (e.statusCode == 401) {
        await _dropSession();
        notifyListeners();
      }
      return const [];
    } on Exception {
      return const [];
    }
  }

  /// Выход: токен на сервере отзывается, локальная сессия удаляется.
  /// Серверный Pro не переносится в офлайн после выхода (подписка привязана
  /// к аккаунту): возвращаемся к локальному состоянию (триал-кэш/Free).
  Future<void> logout() async {
    final s = _session;
    final g = gateway;
    _session = null;
    await sessionStore.clear();
    if (s != null && g != null) {
      try {
        await g.logout(s.token);
      } catch (_) {}
    }
    final cached = await store.load();
    final offline = (cached != null && cached.source == 'local')
        ? cached
        : Entitlement.free;
    _entitlement = offline;
    notifyListeners();
  }

  /// Покупка Pro.
  ///
  /// С gateway: заказ в payments + тестовое подтверждение, затем обновление
  /// подписки с сервера. Без gateway (офлайн/тесты) — локальная заглушка.
  /// 'restore' — перечитать подписку с сервера (или кэш офлайн).
  Future<String?> purchase(String period) async {
    if (period == 'restore') {
      if (gateway != null && _session != null) {
        await _refreshFromServer();
        return null;
      }
      final cached = await store.load();
      if (cached != null) {
        _entitlement = cached;
        notifyListeners();
      }
      return null;
    }
    final g = gateway;
    final s = _session;
    if (g != null && s != null) {
      _busy = true;
      notifyListeners();
      try {
        // Сервер сам продлил подписку — забираем актуальный статус.
        await g.purchase(s.token, period);
        await _refreshFromServer();
        return null;
      } on Exception catch (e) {
        _accountError = e.toString();
        return e.toString();
      } finally {
        _busy = false;
        notifyListeners();
      }
    }
    if (g != null) {
      return 'Сначала войдите в аккаунт';
    }
    // Офлайн-заглушка (тесты/без сети): месяц/год → Pro.
    final now = DateTime.now();
    final until = period == 'year'
        ? now.add(const Duration(days: 365))
        : now.add(const Duration(days: 30));
    _entitlement = Entitlement(
      pro: true,
      until: until,
      trialDaysLeft: 0,
      source: 'local',
    );
    await store.save(_entitlement);
    notifyListeners();
    return null;
  }

  /// Пометка «Pro-экран недоступен» → короткий статус для шапки.
  String get statusLabel {
    if (_entitlement.pro) return 'Pro';
    final t = TrialTimer(_entitlement);
    final d = t.daysLeft;
    if (d > 0) return 'Триал: $d дн.';
    return 'Free';
  }
}
