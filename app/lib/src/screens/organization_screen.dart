/// Экран «Организация и участники» (F-19): список членов, добавление
/// (added/invited по SMTP), удаление; выбор организации при нескольких.
library;

import 'package:flutter/material.dart';

import '../../license/license_controller.dart';

/// Открывает экран организации (требуется вошедшая сессия).
Future<void> openOrganizationScreen(
    BuildContext context, LicenseController license) {
  return Navigator.of(context).push(MaterialPageRoute<void>(
    builder: (_) => OrganizationScreen(license: license),
  ));
}

class OrganizationScreen extends StatefulWidget {
  final LicenseController license;
  const OrganizationScreen({super.key, required this.license});

  @override
  State<OrganizationScreen> createState() => _OrganizationScreenState();
}

class _OrganizationScreenState extends State<OrganizationScreen> {
  final _emailCtrl = TextEditingController();
  List<Map<String, dynamic>> _orgs = const [];
  List<Map<String, dynamic>> _members = const [];
  String? _orgId;
  String _myRole = '';
  String _newRole = 'member';
  bool _loading = true;
  String _message = '';

  LicenseController get license => widget.license;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _emailCtrl.dispose();
    super.dispose();
  }

  Map<String, dynamic>? get _org {
    for (final o in _orgs) {
      if (o['org_id'] == _orgId) return o;
    }
    return null;
  }

  bool get _canManage =>
      _myRole == 'owner' || _myRole == 'admin';

  Future<void> _load() async {
    setState(() => _loading = true);
    final res = await license.organizationList();
    if (!mounted) return;
    if (res.error != null) {
      setState(() {
        _loading = false;
        _message = res.error!;
      });
      return;
    }
    final orgs = res.orgs;
    // Организация по умолчанию: первая с ролью owner/admin, иначе первая.
    String? pick;
    for (final o in orgs) {
      final r = o['role'];
      if (r == 'owner' || r == 'admin') {
        pick = o['org_id'] as String?;
        break;
      }
    }
    pick ??= orgs.isNotEmpty ? orgs.first['org_id'] as String? : null;
    setState(() {
      _orgs = orgs;
      _orgId = pick;
      _loading = false;
      _message = orgs.isEmpty ? 'Организации не найдены' : '';
    });
    if (_orgId != null) await _loadMembers();
  }

  Future<void> _loadMembers() async {
    final orgId = _orgId;
    if (orgId == null) return;
    setState(() => _loading = true);
    final res = await license.membersList(orgId);
    if (!mounted) return;
    setState(() {
      _loading = false;
      if (res.error != null) {
        _message = res.error!;
      } else {
        _members = res.members;
        _message = '';
        final org = _org;
        _myRole = (org?['role'] as String?) ?? '';
      }
    });
  }

  Future<void> _add() async {
    final orgId = _orgId;
    final email = _emailCtrl.text.trim();
    if (orgId == null || email.isEmpty) {
      setState(() => _message = 'Введите email участника');
      return;
    }
    setState(() => _message = '');
    final res = await license.memberAdd(orgId, email, _newRole);
    if (!mounted) return;
    if (res.error != null) {
      setState(() => _message = res.error!);
      return;
    }
    setState(() {
      _message = res.status == 'invited'
          ? 'Приглашение отправлено на $email (письмо с кодом)'
          : 'Участник добавлен с ролью $_newRole';
    });
    _emailCtrl.clear();
    await _loadMembers();
  }

  Future<void> _remove(String userId, String email) async {
    final orgId = _orgId;
    if (orgId == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Убрать участника?'),
        content: Text('Убрать $email из организации?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Отмена')),
          FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Убрать')),
        ],
      ),
    );
    if (confirmed != true) return;
    final err = await license.memberRemove(orgId, userId);
    if (!mounted) return;
    setState(() => _message = err ?? 'Участник убран');
    if (err == null) await _loadMembers();
  }

  @override
  Widget build(BuildContext context) {
    final org = _org;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Организация и участники'),
        actions: [
          IconButton(
            tooltip: 'Обновить',
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (_orgs.length > 1) ...[
            DropdownButtonFormField<String>(
              initialValue: _orgId,
              decoration: const InputDecoration(
                labelText: 'Организация',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              items: _orgs
                  .map((o) => DropdownMenuItem<String>(
                        value: o['org_id'] as String?,
                        child: Text(o['name'] as String? ?? '—',
                            overflow: TextOverflow.ellipsis),
                      ))
                  .toList(),
              onChanged: (v) async {
                setState(() => _orgId = v);
                await _loadMembers();
              },
            ),
            const SizedBox(height: 12),
          ],
          if (org != null)
            Card(
              child: ListTile(
                title: Text(org['name'] as String? ?? '—'),
                subtitle: Text('ваша роль: $_myRole',
                    style: const TextStyle(fontSize: 12.5)),
                trailing: Chip(
                  label: Text(_canManage ? 'управление' : 'просмотр'),
                  visualDensity: VisualDensity.compact,
                ),
              ),
            ),
          const SizedBox(height: 12),
          Text('Участники (${_members.length})',
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          if (_loading)
            const Padding(
              padding: EdgeInsets.all(12),
              child: Center(
                  child: SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2))),
            )
          else
            ..._members.map((m) => ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                      m['role'] == 'owner'
                          ? Icons.star_outline
                          : Icons.person_outline,
                      size: 20),
                  title: Text(m['email'] as String? ?? '—'),
                  subtitle: Text([
                    if ((m['name'] ?? '').toString().isNotEmpty)
                      m['name'] as String?,
                    'роль: ${m['role']}',
                  ].whereType<String>().join(' · '),
                      style: const TextStyle(fontSize: 12.5)),
                  trailing: _canManage
                      ? IconButton(
                          icon: const Icon(Icons.person_remove_outlined,
                              size: 20),
                          tooltip: 'Убрать из организации',
                          onPressed: () => _remove(
                              m['user_id'] as String,
                              m['email'] as String? ?? ''),
                        )
                      : null,
                )),
          if (_message.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(_message,
                style: TextStyle(
                    color: Theme.of(context).colorScheme.error,
                    fontSize: 13.5)),
          ],
          if (_canManage) ...[
            const SizedBox(height: 16),
            const Divider(),
            const SizedBox(height: 8),
            Text('Добавить участника',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            TextField(
              controller: _emailCtrl,
              keyboardType: TextInputType.emailAddress,
              decoration: const InputDecoration(
                labelText: 'Email',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<String>(
                    initialValue: _newRole,
                    decoration: const InputDecoration(
                      labelText: 'Роль',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    items: const [
                      DropdownMenuItem(value: 'member', child: Text('member')),
                      DropdownMenuItem(value: 'viewer', child: Text('viewer')),
                      DropdownMenuItem(value: 'admin', child: Text('admin')),
                    ],
                    onChanged: (v) =>
                        setState(() => _newRole = v ?? 'member'),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: _loading ? null : _add,
                  child: const Text('Добавить'),
                ),
              ],
            ),
            const SizedBox(height: 6),
            const Text(
              'Для нового email уйдёт приглашение по SMTP; существующий '
              'пользователь добавляется сразу.',
              style: TextStyle(fontSize: 12, color: Colors.blueGrey),
            ),
          ],
        ],
      ),
    );
  }
}
