/// Экран аккаунта: вход / регистрация / сброс пароля / профиль (устройства).
library;

import 'package:flutter/material.dart';

import 'account_client.dart';
import 'license_controller.dart';
import '../src/screens/organization_screen.dart';

/// Открывает экран аккаунта (вход/регистрация или профиль).
Future<void> openAccountScreen(
    BuildContext context, LicenseController license) {
  return Navigator.of(context).push(MaterialPageRoute<void>(
    builder: (_) => AccountScreen(license: license),
  ));
}

class AccountScreen extends StatefulWidget {
  final LicenseController license;
  const AccountScreen({super.key, required this.license});

  @override
  State<AccountScreen> createState() => _AccountScreenState();
}

class _AccountScreenState extends State<AccountScreen> {
  final _nameCtrl = TextEditingController();
  final _emailCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  final _pass2Ctrl = TextEditingController();
  final _codeCtrl = TextEditingController();
  final _emailCodeCtrl = TextEditingController();
  final _newPassCtrl = TextEditingController();
  bool _registerMode = false;
  bool _resetMode = false; // шаг «забыли пароль» (email → код → пароль)
  bool _confirmMode = false; // шаг подтверждения (код с почты)
  String _message = '';

  @override
  void initState() {
    super.initState();
    final email = widget.license.accountEmail;
    if (email != null && email.isNotEmpty) _emailCtrl.text = email;
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _emailCtrl.dispose();
    _passCtrl.dispose();
    _pass2Ctrl.dispose();
    _codeCtrl.dispose();
    _emailCodeCtrl.dispose();
    _newPassCtrl.dispose();
    super.dispose();
  }

  LicenseController get license => widget.license;

  Future<void> _submit() async {
    final email = _emailCtrl.text.trim();
    final password = _passCtrl.text;
    if (email.isEmpty || password.isEmpty) {
      setState(() => _message = 'Введите email и пароль');
      return;
    }
    setState(() => _message = '');
    if (_registerMode) {
      final name = _nameCtrl.text.trim();
      if (name.isEmpty) {
        setState(() => _message = 'Введите имя пользователя');
        return;
      }
      if (password != _pass2Ctrl.text) {
        setState(() => _message = 'Пароли не совпадают');
        return;
      }
      final res = await license.register(name, email, password);
      if (!mounted) return;
      if (res.error != null) {
        setState(() => _message = res.error!);
        return;
      }
      setState(() {
        _confirmMode = true;
        _message = _codeMessage(res.devEmailCode);
      });
      return;
    }
    final String? err = await license.login(email, password);
    if (!mounted) return;
    if (err == null) {
      setState(() {
        _message = 'Вы вошли.';
      });
      await Future<void>.delayed(const Duration(milliseconds: 600));
      if (mounted) Navigator.of(context).pop();
    } else if (license.needsConfirm) {
      // 403 «аккаунт не подтверждён» → сразу к вводу кодов.
      setState(() {
        _confirmMode = true;
        _message = err;
      });
    } else {
      setState(() => _message = err);
    }
  }

  static String _codeMessage(String? devEmail) {
    return devEmail != null
        ? 'Код с почты (dev-режим): $devEmail.'
        : 'Код отправлен на email. Введите его ниже.';
  }

  /// Шаг подтверждения: код почты → сессия.
  Future<void> _doConfirm() async {
    final ec = _emailCodeCtrl.text.trim();
    if (ec.isEmpty) {
      setState(() => _message = 'Введите код с почты');
      return;
    }
    setState(() => _message = '');
    final err = await license.confirm(ec);
    if (!mounted) return;
    if (err != null) {
      setState(() => _message = err);
      return;
    }
    setState(() {
      _confirmMode = false;
      _registerMode = false;
      _message = 'Аккаунт подтверждён. Добро пожаловать!';
    });
    await Future<void>.delayed(const Duration(milliseconds: 600));
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _resend() async {
    setState(() => _message = 'Отправляем…');
    final res = await license.resendConfirm();
    if (!mounted) return;
    setState(() {
      _message = res.error ?? _codeMessage(res.devEmailCode);
    });
  }

  /// Шаг 1 сброса: запросить код.
  Future<void> _requestResetCode() async {
    final email = _emailCtrl.text.trim();
    if (email.isEmpty) {
      setState(() => _message = 'Введите email');
      return;
    }
    setState(() {
      _resetMode = true;
      _message = '';
    });
    final res = await license.forgot(email);
    if (!mounted) return;
    if (res.error != null) {
      setState(() {
        _resetMode = false;
        _message = res.error!;
      });
      return;
    }
    final devCode = res.devCode;
    setState(() {
      _resetMode = true;
      _message = devCode != null
          ? 'Код (dev-режим): $devCode. Введите его ниже.'
          : 'Код отправлен на email. Введите его ниже.';
    });
  }

  /// Шаг 2 сброса: код + новый пароль.
  Future<void> _doReset() async {
    final email = _emailCtrl.text.trim();
    final code = _codeCtrl.text.trim();
    final np = _newPassCtrl.text;
    if (email.isEmpty || code.isEmpty || np.isEmpty) {
      setState(() => _message = 'Заполните все поля');
      return;
    }
    setState(() => _message = '');
    final err = await license.reset(email, code, np);
    if (!mounted) return;
    if (err != null) {
      setState(() => _message = err);
      return;
    }
    setState(() {
      _resetMode = false;
      _registerMode = false;
      _message = 'Пароль сброшен. Войдите с новым паролем.';
    });
  }

  Future<void> _logout() async {
    await license.logout();
    if (mounted) setState(() => _message = 'Вы вышли из аккаунта.');
  }

  @override
  Widget build(BuildContext context) {
    final lic = license;
    final logged = lic.loggedIn;
    return Scaffold(
      appBar: AppBar(title: const Text('Аккаунт')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: logged ? _buildProfile(context) : _buildAuth(context),
          ),
        ),
      ),
    );
  }

  Widget _buildProfile(BuildContext context) {
    final lic = license;
    return ListView(
      shrinkWrap: true,
      children: [
        Icon(Icons.account_circle,
            size: 72, color: Theme.of(context).colorScheme.primary),
        const SizedBox(height: 12),
        Text(lic.accountEmail ?? '',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 16),
        Text('Статус: ${lic.statusLabel}', textAlign: TextAlign.center),
        if (lic.entitlement.pro && lic.entitlement.until != null)
          Text('Pro до ${_fmt(lic.entitlement.until!)}',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 8),
        _SubscriptionActions(license: license),
        const SizedBox(height: 12),
        // Устройства: лимит 1/1.
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.devices, size: 18),
            const SizedBox(width: 8),
            Text('Устройства: 1/1',
                style: Theme.of(context).textTheme.bodyMedium),
          ],
        ),
        const SizedBox(height: 12),
        _DeviceList(license: license),
        const SizedBox(height: 20),
        if (_message.isNotEmpty) ...[
          Text(_message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.blueGrey)),
          const SizedBox(height: 8),
        ],
        FilledButton.tonal(
          onPressed: () => openOrganizationScreen(context, lic),
          child: const Text('Организация и участники'),
        ),
        const SizedBox(height: 8),
        FilledButton.tonal(
          onPressed: lic.busy ? null : _logout,
          child: const Text('Выйти'),
        ),
      ],
    );
  }

  Widget _buildAuth(BuildContext context) {
    final lic = license;
    return ListView(
      shrinkWrap: true,
      children: [
        Icon(Icons.account_circle,
            size: 72, color: Theme.of(context).colorScheme.primary),
        const SizedBox(height: 12),
        Text(
          _resetMode
              ? 'Сброс пароля'
              : (_confirmMode
                  ? 'Подтверждение регистрации'
                  : (_registerMode ? 'Регистрация' : 'Вход')),
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 16),
        if (_registerMode && !_confirmMode && !_resetMode) ...[
          TextField(
            controller: _nameCtrl,
            decoration: const InputDecoration(
                labelText: 'Имя пользователя',
                border: OutlineInputBorder(),
                isDense: true),
          ),
          const SizedBox(height: 12),
        ],
        TextField(
          controller: _emailCtrl,
          enabled: !_confirmMode,
          keyboardType: TextInputType.emailAddress,
          decoration: const InputDecoration(
              labelText: 'Email',
              border: OutlineInputBorder(),
              isDense: true),
        ),
        const SizedBox(height: 12),
        if (_confirmMode) ...[
          TextField(
            controller: _emailCodeCtrl,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
                labelText: 'Код с почты',
                helperText: 'Из письма о регистрации',
                border: OutlineInputBorder(),
                isDense: true),
            onSubmitted: (_) => _doConfirm(),
          ),
        ] else if (_resetMode) ...[
          TextField(
            controller: _codeCtrl,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
                labelText: 'Код из письма',
                border: OutlineInputBorder(),
                isDense: true),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _newPassCtrl,
            obscureText: true,
            decoration: const InputDecoration(
                labelText: 'Новый пароль',
                helperText: 'Не менее 6 символов',
                border: OutlineInputBorder(),
                isDense: true),
            onSubmitted: (_) => _doReset(),
          ),
        ] else ...[
          TextField(
            controller: _passCtrl,
            obscureText: true,
            decoration: const InputDecoration(
                labelText: 'Пароль',
                helperText: 'Не менее 6 символов',
                border: OutlineInputBorder(),
                isDense: true),
            onSubmitted: (_) => _submit(),
          ),
          if (_registerMode) ...[
            const SizedBox(height: 12),
            TextField(
              controller: _pass2Ctrl,
              obscureText: true,
              decoration: const InputDecoration(
                  labelText: 'Повторите пароль',
                  border: OutlineInputBorder(),
                  isDense: true),
              onSubmitted: (_) => _submit(),
            ),
          ],
        ],
        if (_message.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(_message, style: const TextStyle(color: Colors.redAccent)),
        ],
        const SizedBox(height: 16),
        if (_confirmMode)
          FilledButton(
            onPressed: lic.busy ? null : _doConfirm,
            child: const Text('Подтвердить'),
          )
        else if (_resetMode)
          FilledButton(
            onPressed: lic.busy ? null : _doReset,
            child: const Text('Сбросить пароль'),
          )
        else
          FilledButton(
            onPressed: lic.busy ? null : _submit,
            child: Text(_registerMode ? 'Создать аккаунт' : 'Войти'),
          ),
        if (_confirmMode) ...[
          TextButton(
            onPressed: lic.busy ? null : _resend,
            child: const Text('Код на почту повторно'),
          ),
          TextButton(
            onPressed: () {
              license.cancelConfirm();
              setState(() {
                _confirmMode = false;
                _registerMode = false;
                _emailCodeCtrl.clear();
                _message = '';
              });
            },
            child: const Text('Назад ко входу'),
          ),
        ] else if (_resetMode)
          TextButton(
            onPressed: () => setState(() {
              _resetMode = false;
              _message = '';
            }),
            child: const Text('Назад ко входу'),
          )
        else ...[
          TextButton(
            onPressed: () => setState(() {
              _registerMode = !_registerMode;
              _message = '';
            }),
            child: Text(_registerMode
                ? 'Уже есть аккаунт — войти'
                : 'Нет аккаунта — зарегистрироваться'),
          ),
          if (!_registerMode)
            TextButton(
              onPressed: _requestResetCode,
              child: const Text('Забыли пароль?'),
            ),
        ],
      ],
    );
  }

  static String _fmt(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}.'
      '${d.month.toString().padLeft(2, '0')}.${d.year}';
}

/// Управление автопродлением подписки: состояние, отмена, возобновление.
/// Показывается, только когда есть что показать (карта привязана либо
/// продление отменено).
class _SubscriptionActions extends StatefulWidget {
  final LicenseController license;
  const _SubscriptionActions({required this.license});

  @override
  State<_SubscriptionActions> createState() => _SubscriptionActionsState();
}

class _SubscriptionActionsState extends State<_SubscriptionActions> {
  ServerSubscription? _sub;
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  LicenseController get license => widget.license;

  Future<void> _load() async {
    final res = await license.subscriptionState();
    if (!mounted) return;
    setState(() {
      _sub = res.sub;
      _error = res.error;
      _loading = false;
    });
  }

  Future<void> _run(Future<String?> Function() action) async {
    final err = await action();
    if (!mounted) return;
    if (err != null) {
      setState(() => _error = err);
      return;
    }
    setState(() {
      _error = null;
      _loading = true;
    });
    await _load();
  }

  String _fmt(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}.'
      '${d.month.toString().padLeft(2, '0')}.${d.year}';

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.all(4),
        child: Center(
            child: SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2))),
      );
    }
    final sub = _sub;
    final children = <Widget>[];
    if (sub != null &&
        (sub.autoRenew || sub.cancelAtPeriodEnd)) {
      final until = sub.until != null ? _fmt(sub.until!) : '';
      children.add(Text(
          sub.plan == 'year' ? 'Подписка: Pro на год' : 'Подписка: Pro на месяц',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodyMedium));
      if (sub.cancelAtPeriodEnd) {
        children.add(Text(
            'Продление отменено — доступ сохранится до $until, '
            'новых списаний не будет.',
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.blueGrey, fontSize: 12)));
        children.add(TextButton(
          onPressed:
              license.busy ? null : () => _run(license.resumeSubscription),
          child: const Text('Включить автопродление'),
        ));
      } else {
        children.add(const Text(
            'Автопродление включено: карта спишется за сутки до конца периода.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.blueGrey, fontSize: 12)));
        children.add(TextButton(
          onPressed:
              license.busy ? null : () => _run(license.cancelSubscription),
          child: const Text('Отменить автопродление'),
        ));
      }
    }
    if (_error != null) {
      children.add(Text(_error!,
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.redAccent, fontSize: 12)));
    }
    if (children.isEmpty) return const SizedBox.shrink();
    return Column(children: children);
  }
}

/// Список устройств аккаунта (лимит 1/1): текущее и «войти на другом —
/// вытеснит это».
class _DeviceList extends StatefulWidget {
  final LicenseController license;
  const _DeviceList({required this.license});

  @override
  State<_DeviceList> createState() => _DeviceListState();
}

class _DeviceListState extends State<_DeviceList> {
  List<AccountDevice> _devices = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final d = await widget.license.devices();
    if (!mounted) return;
    setState(() {
      _devices = d;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.all(8),
        child: Center(
            child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2))),
      );
    }
    if (_devices.isEmpty) {
      return const Text('Устройства не найдены',
          style: TextStyle(color: Colors.blueGrey));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final d in _devices)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(d.current ? Icons.computer : Icons.devices,
                size: 20),
            title: Text(d.deviceId.length > 24
                ? 'Устройство ${d.deviceId.substring(0, 8)}…'
                : d.deviceId),
            subtitle: Text(d.current ? 'Это устройство' : ''),
          ),
        const Text(
          'Вход с другого устройства вытеснит это (лимит 1/1).',
          style: TextStyle(color: Colors.blueGrey, fontSize: 12),
        ),
      ],
    );
  }
}

/// Кнопка-чип аккаунта для шапки: показывает email/«Войти».
class AccountButton extends StatelessWidget {
  final LicenseController license;
  const AccountButton({super.key, required this.license});

  @override
  Widget build(BuildContext context) {
    final logged = license.loggedIn;
    return ListenableBuilder(
      listenable: license,
      builder: (context, _) => Tooltip(
        message: logged ? 'Аккаунт: ${license.accountEmail}' : 'Войти в аккаунт',
        child: TextButton.icon(
          onPressed: () => openAccountScreen(context, license),
          icon: Icon(logged ? Icons.account_circle : Icons.login,
              size: 18),
          label: Text(
              logged ? (license.accountEmail ?? 'Аккаунт') : 'Войти'),
        ),
      ),
    );
  }
}
