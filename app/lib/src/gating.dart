/// Гейтинг Free/Pro. Пока пакет лицензий (аг.12) не подключён — всё Pro.
library;

/// Интерфейс гейтинга; реализация подключается пакетом license (аг.12).
class FeatureGate {
  final bool isPro;
  const FeatureGate({this.isPro = true});

  /// Может ли пользователь выполнить действие Pro-уровня.
  bool allows(String feature) => isPro;
}

/// Глобальный (пока константный) гейт.
const featureGate = FeatureGate(isPro: true);
