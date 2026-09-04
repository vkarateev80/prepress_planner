/// Экран аккаунта: вход / регистрация / статус и выход.
library;

import 'package:flutter/material.dart';

import 'license_controller.dart';

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
  final _emailCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  bool _registerMode = false;
  String _message = '';

  @override
  void initState() {
    super.initState();
    final email = widget.license.accountEmail;
    if (email != null && email.isNotEmpty) _emailCtrl.text = email;
  }

  @override
  void dispose() {
    _emailCtrl.dispose();
    _passCtrl.dispose();
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
    final String? err = _registerMode
        ? await license.register(email, password)
        : await license.login(email, password);
    if (!mounted) return;
    if (err == null) {
      setState(() {
        _message = _registerMode
            ? 'Аккаунт создан. Добро пожаловать!'
            : 'Вы вошли.';
      });
      await Future<void>.delayed(const Duration(milliseconds: 600));
      if (mounted) Navigator.of(context).pop();
    } else {
      setState(() => _message = err);
    }
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
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Icon(Icons.account_circle,
                    size: 72,
                    color: Theme.of(context).colorScheme.primary),
                const SizedBox(height: 12),
                if (logged)
                  Text(lic.accountEmail ?? '',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.titleMedium)
                else
                  Text(_registerMode ? 'Регистрация' : 'Вход',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 16),
                if (logged) ...[
                  Text('Статус: ${lic.statusLabel}',
                      textAlign: TextAlign.center),
                  const SizedBox(height: 16),
                  if (lic.entitlement.until != null &&
                      lic.entitlement.pro)
                    Text('Pro до ${_fmt(lic.entitlement.until!)}',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodySmall),
                  const SizedBox(height: 16),
                  FilledButton.tonal(
                    onPressed: lic.busy ? null : _logout,
                    child: const Text('Выйти'),
                  ),
                ] else ...[
                  TextField(
                    controller: _emailCtrl,
                    keyboardType: TextInputType.emailAddress,
                    decoration: const InputDecoration(
                        labelText: 'Email',
                        border: OutlineInputBorder(),
                        isDense: true),
                  ),
                  const SizedBox(height: 12),
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
                  if (_message.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text(_message,
                        style: const TextStyle(color: Colors.redAccent)),
                  ],
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed: lic.busy ? null : _submit,
                    child: Text(_registerMode ? 'Создать аккаунт' : 'Войти'),
                  ),
                  TextButton(
                    onPressed: () => setState(() {
                      _registerMode = !_registerMode;
                      _message = '';
                    }),
                    child: Text(_registerMode
                        ? 'Уже есть аккаунт — войти'
                        : 'Нет аккаунта — зарегистрироваться'),
                  ),
                ],
                const SizedBox(height: 8),
                if (_message.isNotEmpty && logged)
                  Text(_message,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.blueGrey)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  static String _fmt(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}.'
      '${d.month.toString().padLeft(2, '0')}.${d.year}';
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
