/// Кэш энтайтлментов (JSON: файл на desktop / localStorage на web) +
/// FeatureGate + таймер триала.
library;

import 'dart:convert';

import '../platform/json_store.dart';
import 'license_client.dart';

/// Хранилище энтайтлментов: JSON (файл или localStorage — среда сама решит).
class EntitlementStore {
  final JsonStore _store;
  EntitlementStore(String directory) : _store = JsonStore(directory);

  Future<void> save(Entitlement e) async {
    await _store.write('entitlement.json', jsonEncode(e.toJson()));
  }

  Future<Entitlement?> load() async {
    final s = await _store.read('entitlement.json');
    if (s == null) return null;
    try {
      final j = jsonDecode(s) as Map<String, dynamic>;
      return Entitlement.fromJson(j);
    } catch (_) {
      return null;
    }
  }

  /// Офлайн-грэйс 30 дней от даты в кэше.
  bool isWithinGrace(Entitlement e, {DateTime? now}) {
    final until = e.until;
    if (until == null) return false;
    final n = now ?? DateTime.now();
    return n.isBefore(until.add(const Duration(days: 30)));
  }
}

/// Гейтинг функций по подписке.
class FeatureGate {
  final Entitlement entitlement;
  const FeatureGate(this.entitlement);

  bool get isPro => entitlement.pro;

  /// Триал ещё не истёк (Pro не куплен).
  bool get isTrialActive =>
      !entitlement.pro &&
      entitlement.until != null &&
      entitlement.until!.isAfter(DateTime.now());

  /// Полный доступ: Pro или активный триал.
  bool get hasProAccess => isPro || isTrialActive;

  bool get isTrial => entitlement.trialDaysLeft > 0 && !entitlement.pro;

  /// Free: 1 проект, прямоугольный расчёт. Pro/триал: всё.
  bool allows(String feature) {
    if (hasProAccess) return true;
    switch (feature) {
      case 'project.create':
      case 'layout.rect':
        return true;
      default:
        return false;
    }
  }
}

/// «Пробный период: осталось N дней».
class TrialTimer {
  final Entitlement entitlement;
  const TrialTimer(this.entitlement);

  int get daysLeft {
    final until = entitlement.until;
    if (until == null) return 0;
    final diff = until.difference(DateTime.now());
    if (diff.isNegative) return 0;
    // Неполные сутки округляем вверх: 9 сут 23:59 -> «10 дн.».
    return (diff.inSeconds / Duration.secondsPerDay).ceil();
  }

  String get label {
    if (entitlement.pro) return 'Pro активна';
    final d = daysLeft;
    if (d > 0) return 'Пробный период: осталось $d дн.';
    return 'Пробный период истёк';
  }
}
