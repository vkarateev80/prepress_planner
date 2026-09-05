/// Клиент лицензий: HTTP к services/license или заглушка (без сети).
/// MachineId — стабильный идентификатор устройства (JSON-хранилище).
library;

import 'dart:convert';

import '../platform/http.dart';
import '../platform/json_store.dart';

/// Энтайтлменты устройства.
class Entitlement {
  final bool pro;
  final DateTime? until;
  final int trialDaysLeft;
  final String source; // 'server' | 'cache' | 'local'
  const Entitlement({
    this.pro = false,
    this.until,
    this.trialDaysLeft = 0,
    this.source = 'local',
  });

  Map<String, dynamic> toJson() => {
        'pro': pro,
        'until': until?.toIso8601String(),
        'trialDaysLeft': trialDaysLeft,
        'source': source,
      };

  factory Entitlement.fromJson(Map<String, dynamic> j) => Entitlement(
        pro: j['pro'] == true,
        until: j['until'] == null
            ? null
            : DateTime.tryParse(j['until'] as String),
        trialDaysLeft: (j['trialDaysLeft'] as num?)?.toInt() ?? 0,
        source: (j['source'] as String?) ?? 'local',
      );

  static const free = Entitlement();
}

/// Заглушка без сети: 15-дневный триал от первого запуска (локально).
/// В проде заменяется на HTTP-клиент services/license.
class LicenseClient {
  final String? serverUrl; // null — офлайн-заглушка

  LicenseClient({this.serverUrl});

  /// Активация: без ключа — локальный триал 15 дней.
  Future<Entitlement> activate(String machineId, {String? key}) async {
    final url = serverUrl;
    if (url != null && url.isNotEmpty) {
      try {
        final resp = await httpJsonPost('$url/license/activate',
            json: {'machine_id': machineId, 'key': key},
            timeout: const Duration(seconds: 5));
        final data = jsonDecode(resp.text) as Map<String, dynamic>;
        return Entitlement(
          pro: data['status'] == 'active' || data['status'] == 'trial',
          until: data['expires_at'] == null
              ? null
              : DateTime.tryParse(data['expires_at'] as String),
          source: 'server',
        );
      } catch (_) {
        // Сеть недоступна — локальный кэш/заглушка.
      }
    }
    // Офлайн-заглушка: триал 15 дней с первой активации.
    final now = DateTime.now();
    return Entitlement(
      pro: false,
      until: now.add(const Duration(days: 15)),
      trialDaysLeft: 15,
      source: 'local',
    );
  }

  Future<Entitlement> validate(String machineId) async {
    final url = serverUrl;
    if (url != null && url.isNotEmpty) {
      try {
        final resp = await httpJsonPost('$url/license/validate',
            json: {'machine_id': machineId},
            timeout: const Duration(seconds: 5));
        final data = jsonDecode(resp.text) as Map<String, dynamic>;
        return Entitlement(
          pro: data['pro'] == true,
          until: data['until'] == null
              ? null
              : DateTime.tryParse(data['until'] as String),
          trialDaysLeft: (data['trial_days_left'] as num?)?.toInt() ?? 0,
          source: 'server',
        );
      } catch (_) {
        // offline
      }
    }
    return Entitlement.free;
  }
}

/// Стабильный machine-id: UUID в файле (desktop) / localStorage (web).
class MachineId {
  static Future<String> load(String directory) async {
    final store = JsonStore(directory);
    final existing = await store.read('machine_id.txt');
    if (existing != null && existing.trim().isNotEmpty) {
      return existing.trim();
    }
    final id = _uuid();
    await store.write('machine_id.txt', id);
    return id;
  }

  static String _uuid() {
    final r = _Random();
    final b = List<int>.generate(16, (_) => r.nextInt(256));
    b[6] = (b[6] & 0x0F) | 0x40;
    b[8] = (b[8] & 0x3F) | 0x80;
    String h(int v) => v.toRadixString(16).padLeft(2, '0');
    return '${h(b[0])}${h(b[1])}${h(b[2])}${h(b[3])}-'
        '${h(b[4])}${h(b[5])}-${h(b[6])}${h(b[7])}-'
        '${h(b[8])}${h(b[9])}-${h(b[10])}${h(b[11])}'
        '${h(b[12])}${h(b[13])}${h(b[14])}${h(b[15])}';
  }
}

class _Random {
  int _s = DateTime.now().microsecondsSinceEpoch;
  int nextInt(int max) {
    _s = (_s * 1103515245 + 12345) & 0x7FFFFFFF;
    return _s % max;
  }
}
