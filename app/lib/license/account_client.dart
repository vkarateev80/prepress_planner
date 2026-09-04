/// Клиенты аккаунта: авторизация (auth) и оплата (payments).
///
/// Без внешних pub-пакетов: dart:io HttpClient. Токен (Bearer) выдаёт auth;
/// payments проверяет его той же HMAC-подписью. Адреса по умолчанию — VPS:
///   auth     — env PP_AUTH_URL     либо http://193.233.193.12:8121
///   payments — env PP_PAYMENTS_URL либо http://193.233.193.12:8122
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Ошибка API с русским сообщением для UI.
class ApiException implements Exception {
  final String message;
  final int statusCode;
  const ApiException(this.message, {this.statusCode = 0});

  @override
  String toString() => message;
}

/// Сессия пользователя: токен + email.
class AccountSession {
  final String token;
  final String email;
  const AccountSession({required this.token, required this.email});

  Map<String, dynamic> toJson() => {'token': token, 'email': email};

  factory AccountSession.fromJson(Map<String, dynamic> j) => AccountSession(
        token: (j['token'] as String?) ?? '',
        email: (j['email'] as String?) ?? '',
      );
}

/// Состояние подписки с сервера оплаты.
class ServerSubscription {
  final String? plan;
  final bool pro;
  final DateTime? until;
  const ServerSubscription({this.plan, this.pro = false, this.until});

  factory ServerSubscription.fromJson(Map<String, dynamic> j) {
    final until = j['until'];
    return ServerSubscription(
      plan: j['plan'] as String?,
      pro: j['pro'] == true,
      until: until == null ? null : DateTime.tryParse(until.toString()),
    );
  }
}

/// Хранилище сессии на диске: state/session.json.
class SessionStore {
  final String directory;
  SessionStore(this.directory);

  Future<void> save(AccountSession s) async {
    final dir = Directory(directory);
    await dir.create(recursive: true);
    await File('${dir.path}/session.json')
        .writeAsString(jsonEncode(s.toJson()), flush: true);
  }

  Future<AccountSession?> load() async {
    final f = File('${directory == '' ? '.' : directory}/session.json');
    if (!await f.exists()) return null;
    try {
      final j = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      final s = AccountSession.fromJson(j);
      return s.token.isEmpty ? null : s;
    } catch (_) {
      return null;
    }
  }

  Future<void> clear() async {
    final f = File('${directory == '' ? '.' : directory}/session.json');
    if (await f.exists()) {
      try {
        await f.delete();
      } catch (_) {}
    }
  }
}

/// Шлюз аккаунта: auth + payments. В тестах подменяется фейком.
abstract class AccountGateway {
  /// Регистрация: email+пароль → сессия.
  Future<AccountSession> register(String email, String password);

  /// Вход: email+пароль → сессия.
  Future<AccountSession> login(String email, String password);

  /// Выход (токен на сервере отзывается; локально токен удаляется).
  Future<void> logout(String token);

  /// Текущая подписка пользователя по токену.
  Future<ServerSubscription> subscription(String token);

  /// Тарифы: [{plan, title, amount_rub}].
  Future<List<Map<String, dynamic>>> plans(String token);

  /// Создать заказ (заглушка) и оплатить его тестовым подтверждением.
  /// Возвращает {order_id, plan, until}.
  Future<Map<String, dynamic>> purchase(String token, String plan);
}

/// HTTP-реализация шлюза поверх микросервисов auth/payments.
class AccountGatewayHttp implements AccountGateway {
  final AuthApi auth;
  final PaymentsApi payments;
  AccountGatewayHttp({AuthApi? auth, PaymentsApi? payments})
      : auth = auth ?? AuthApi(),
        payments = payments ?? PaymentsApi();

  @override
  Future<AccountSession> register(String email, String password) =>
      auth.register(email, password);

  @override
  Future<AccountSession> login(String email, String password) =>
      auth.login(email, password);

  @override
  Future<void> logout(String token) => auth.logout(token);

  @override
  Future<ServerSubscription> subscription(String token) async {
    final j = await payments.subscription(token);
    return ServerSubscription.fromJson(j);
  }

  @override
  Future<List<Map<String, dynamic>>> plans(String token) =>
      payments.plans(token);

  @override
  Future<Map<String, dynamic>> purchase(String token, String plan) async {
    final order = await payments.checkout(token, plan);
    final orderId = order['order_id'] as String;
    if (orderId.isEmpty) {
      throw const ApiException('Сервер не вернул order_id');
    }
    await payments.confirm(token, orderId);
    return order;
  }
}

/// Клиент микросервиса авторизации.
class AuthApi {
  final String baseUrl;
  AuthApi({String? baseUrl}) : baseUrl = baseUrl ?? defaultUrl();

  static String defaultUrl() {
    final env = Platform.environment['PP_AUTH_URL']?.trim();
    if (env != null && env.isNotEmpty) return env;
    return 'http://193.233.193.12:8121';
  }

  static const _timeout = Duration(seconds: 8);

  Future<AccountSession> register(String email, String password) =>
      _post('/auth/register', {'email': email, 'password': password});

  Future<AccountSession> login(String email, String password) =>
      _post('/auth/login', {'email': email, 'password': password});

  Future<AccountSession> _post(String path, Map<String, dynamic> body) async {
    final client = HttpClient()..connectionTimeout = _timeout;
    try {
      final req = await client
          .postUrl(Uri.parse('$_base$path'))
          .timeout(_timeout);
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode(body));
      final resp = await req.close().timeout(_timeout);
      final text = await utf8.decodeStream(resp).timeout(_timeout);
      if (resp.statusCode == 200) {
        final j = jsonDecode(text) as Map<String, dynamic>;
        final token = j['token'] as String?;
        final user = j['user'] as Map<String, dynamic>?;
        if (token == null || token.isEmpty) {
          throw const ApiException('Сервер не вернул токен.');
        }
        return AccountSession(
            token: token, email: (user?['email'] as String?) ?? '');
      }
      throw ApiException(_detail(text), statusCode: resp.statusCode);
    } on ApiException {
      rethrow;
    } on SocketException {
      throw const ApiException('Сервер авторизации недоступен. Проверьте сеть.');
    } on TimeoutException {
      throw const ApiException('Сервер авторизации не отвечает.');
    } finally {
      client.close(force: true);
    }
  }

  Future<void> logout(String token) async {
    final client = HttpClient()..connectionTimeout = _timeout;
    try {
      final req = await client
          .postUrl(Uri.parse('$_base/auth/logout'))
          .timeout(_timeout);
      req.headers.set('Authorization', 'Bearer $token');
      final resp = await req.close().timeout(_timeout);
      await resp.drain<void>();
    } on Exception {
      // Выход локальный: сервер недоступен — не критично.
    } finally {
      client.close(force: true);
    }
  }

  String get _base =>
      baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl;

  static String _detail(String text) {
    try {
      final j = jsonDecode(text);
      if (j is Map && j['detail'] != null) {
        return j['detail'].toString();
      }
    } catch (_) {}
    return text.isEmpty ? 'ошибка сервера' : text.trim();
  }
}

/// Клиент микросервиса оплаты.
class PaymentsApi {
  final String baseUrl;
  PaymentsApi({String? baseUrl}) : baseUrl = baseUrl ?? defaultUrl();

  static String defaultUrl() {
    final env = Platform.environment['PP_PAYMENTS_URL']?.trim();
    if (env != null && env.isNotEmpty) return env;
    return 'http://193.233.193.12:8122';
  }

  static const _timeout = Duration(seconds: 8);

  String get _base =>
      baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl;

  Future<List<Map<String, dynamic>>> plans(String token) async {
    final j = await _get('/payments/plans', token);
    return (j as List).cast<Map<String, dynamic>>();
  }

  Future<Map<String, dynamic>> subscription(String token) async {
    final j = await _get('/payments/subscription', token);
    return (j as Map).cast<String, dynamic>();
  }

  Future<Map<String, dynamic>> checkout(String token, String plan) async {
    final j = await _post('/payments/checkout', token, {'plan': plan});
    return (j as Map).cast<String, dynamic>();
  }

  Future<void> confirm(String token, String orderId) async {
    await _post('/payments/orders/$orderId/confirm', token, const {});
  }

  Future<Object?> _get(String path, String token) async {
    final client = HttpClient()..connectionTimeout = _timeout;
    try {
      final req =
          await client.getUrl(Uri.parse('$_base$path')).timeout(_timeout);
      req.headers.set('Authorization', 'Bearer $token');
      final resp = await req.close().timeout(_timeout);
      final text = await utf8.decodeStream(resp).timeout(_timeout);
      if (resp.statusCode == 200) return jsonDecode(text);
      throw ApiException(_detail(text), statusCode: resp.statusCode);
    } on ApiException {
      rethrow;
    } on SocketException {
      throw const ApiException('Сервер оплаты недоступен. Проверьте сеть.');
    } on TimeoutException {
      throw const ApiException('Сервер оплаты не отвечает.');
    } finally {
      client.close(force: true);
    }
  }

  Future<Object?> _post(
      String path, String token, Map<String, dynamic> body) async {
    final client = HttpClient()..connectionTimeout = _timeout;
    try {
      final req = await client
          .postUrl(Uri.parse('$_base$path'))
          .timeout(_timeout);
      req.headers.contentType = ContentType.json;
      req.headers.set('Authorization', 'Bearer $token');
      req.write(jsonEncode(body));
      final resp = await req.close().timeout(_timeout);
      final text = await utf8.decodeStream(resp).timeout(_timeout);
      if (resp.statusCode == 200) {
        return text.isEmpty ? null : jsonDecode(text);
      }
      throw ApiException(_detail(text), statusCode: resp.statusCode);
    } on ApiException {
      rethrow;
    } on SocketException {
      throw const ApiException('Сервер оплаты недоступен. Проверьте сеть.');
    } on TimeoutException {
      throw const ApiException('Сервер оплаты не отвечает.');
    } finally {
      client.close(force: true);
    }
  }

  static String _detail(String text) {
    try {
      final j = jsonDecode(text);
      if (j is Map && j['detail'] != null) {
        return j['detail'].toString();
      }
    } catch (_) {}
    return text.isEmpty ? 'ошибка сервера' : text.trim();
  }
}
