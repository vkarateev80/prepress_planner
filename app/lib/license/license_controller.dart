/// Контроллер лицензии в приложении: bootstrap триала, кэш, покупка.
library;

import 'package:flutter/foundation.dart';

import 'entitlement_store.dart';
import 'license_client.dart';

/// Связывает [EntitlementStore] (кэш), [LicenseClient] (сервер/заглушка)
/// и [MachineId]; уведомляет UI об изменениях энтайтлмента.
class LicenseController extends ChangeNotifier {
  final EntitlementStore store;
  final LicenseClient client;
  final String stateDir; // каталог для machine_id.txt

  Entitlement _entitlement = Entitlement.free;
  bool _ready = false;

  LicenseController({
    required this.store,
    required this.client,
    required this.stateDir,
  });

  Entitlement get entitlement => _entitlement;
  bool get ready => _ready;
  FeatureGate get gate => FeatureGate(_entitlement);
  TrialTimer get timer => TrialTimer(_entitlement);

  /// Первый запуск: если кэша нет — активируем триал 15 дней и сохраняем.
  Future<void> init() async {
    final cached = await store.load();
    if (cached != null) {
      _entitlement = cached;
    } else {
      final machineId = await MachineId.load(stateDir);
      final e = await client.activate(machineId);
      _entitlement = e;
      await store.save(e);
    }
    _ready = true;
    notifyListeners();
  }

  /// Покупка (заглушка до IAP): месяц/год → Pro; restore — перечитать кэш.
  Future<void> purchase(String period) async {
    if (period == 'restore') {
      final cached = await store.load();
      if (cached != null) {
        _entitlement = cached;
        notifyListeners();
      }
      return;
    }
    final now = DateTime.now();
    final until = period == 'year'
        ? now.add(const Duration(days: 365))
        : now.add(const Duration(days: 30));
    final e = Entitlement(
      pro: true,
      until: until,
      trialDaysLeft: 0,
      source: 'local',
    );
    _entitlement = e;
    await store.save(e);
    notifyListeners();
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
