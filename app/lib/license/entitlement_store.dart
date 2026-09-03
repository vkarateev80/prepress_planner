/// Кэш энтайтлментов на диске + FeatureGate + таймер триала.
library;

import 'dart:convert';
import 'dart:io';

import 'license_client.dart';

/// Хранилище энтайтлментов: JSON на диске.
class EntitlementStore {
  final String directory;
  EntitlementStore(this.directory);

  Future<void> save(Entitlement e) async {
    final dir = Directory(directory);
    await dir.create(recursive: true);
    await File('${dir.path}/entitlement.json')
        .writeAsString(jsonEncode(e.toJson()));
  }

  Future<Entitlement?> load() async {
    final f = File('${directory == '' ? '.' : directory}/entitlement.json');
    if (!await f.exists()) return null;
    try {
      final j = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
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
  bool get isTrial => entitlement.trialDaysLeft > 0 && !entitlement.pro;

  /// Free: 1 проект, прямоугольный расчёт. Pro: всё.
  bool allows(String feature) {
    if (isPro) return true;
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
