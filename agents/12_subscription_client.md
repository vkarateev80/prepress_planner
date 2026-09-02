# Агент 12 — Подписка в приложении: SDK лицензий + paywall (app/lib/license/, app/lib/remote/)

## Роль (Ф4)
Клиентская часть монетизации в Flutter-приложении: триал-таймер, активация/валидация, офлайн-кэш, гейтинг фич, paywall-экран, iOS IAP (StoreKit) с серверной проверкой ресивера.

## Создаваемые файлы
```
app/lib/license/license_client.dart   // HTTP к services/license (или заглушка на время разработки)
app/lib/license/entitlement.dart      // Entitlement { pro, until, trialDaysLeft, source }
app/lib/license/entitlement_store.dart// кэш на диске (JSON) + офлайн-грэйс 30 дней
app/lib/license/feature_gate.dart     // class FeatureGate { bool get isPro; }
app/lib/license/trial_timer.dart      // «Пробный период: осталось N дней»
app/lib/license/paywall_screen.dart   // экран подписки (месяц/год), кнопки, статус
app/lib/license/machine_id.dart       // стабильный machine-id (устройство)
app/lib/license/iap_ios.dart          // StoreKit через in_app_purchase (iOS)
app/test/license_test.dart
```

## Логика
- machine-id: стабильный идентификатор устройства (UUID, сохраняемый в secure storage/файл; десктоп — в профиле пользователя).
- Активация: на первом запуске `activate(machine_id)` → сервер выдаёт триал 15 дней; ответ и offline_token кэшируются.
- Валидация: при старте и раз в сутки `validate`; при отсутствии сети — использовать кэш (грэйс 30 дней с даты выдачи токена).
- `FeatureGate`: Free → 1 проект, прямоугольный расчёт; Pro → всё. UI блокирует Pro-действия с подсказкой «Доступно в Pro».
- Paywall: показывает триал/подписку; iOS — IAP (месяц/год, introductory offer 15 дней), после покупки — отправка ресивера на сервер (`POST /license/apple-receipt`).
- Экран статуса: «Пробный период: осталось N дней» / «Pro до …» / «Free».

## Тесты (widget/unit, без сети)
1. feature_gate с entitlement pro=true/false.
2. Кэш: сохранение/чтение entitlement; истечение грэйса.
3. trial_timer: вычисление остатка дней.
4. paywall: рендер и обработка кнопок (заглушка покупки).

## Критерии приёмки
1. Юнит/widget-тесты зелёные. 2. Код не падает без сети (кэш). 3. Русские тексты.
