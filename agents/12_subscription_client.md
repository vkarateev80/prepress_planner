# Агент 12 — Аккаунт и подписка в приложении (app/lib/license/)

## Роль (Ф4)
Клиентская часть монетизации в Flutter-приложении: вход/регистрация по
email+пароль, подписка Pro с микросервиса оплаты, офлайн-фолбэк, гейтинг
фич, paywall-экран.

## Создаваемые файлы
```
app/lib/license/account_client.dart       // AuthApi/PaymentsApi (dart:io), AccountGateway
app/lib/license/account_screen.dart       // экран входа/регистрации/профиля + AccountButton
app/lib/license/license_client.dart       // офлайн-заглушка (триал 15 дней) — фолбэк
app/lib/license/license_controller.dart   // сессия, синхронизация подписки, покупка, выход
app/lib/license/entitlement_store.dart    // кэш entitlement (JSON) + грэйс
app/lib/license/paywall_screen.dart       // paywall: покупка через контроллер
app/test/license_account_test.dart
```

## Логика
- AccountGateway (интерфейс) + AccountGatewayHttp: register/login/logout →
  auth; subscription/plans/checkout/confirm → payments. В тестах — фейк.
- LicenseController:
  - `init()`: восстановление сессии (state/session.json) → кэш → сервер;
    без всего — офлайн-триал 15 дней (фолбэк, без сети).
  - `login/register`: gateway → сессия сохраняется → подписка с сервера.
  - `purchase(month|year)`: заказ в payments + тестовое подтверждение →
    обновление подписки. 'restore' — перечитать с сервера/кэш.
  - `logout()`: токен отзывается, сессия удаляется, серверный Pro НЕ
    переносится в офлайн (подписка привязана к аккаунту).
  - Без gateway (офлайн/тесты) — прежняя локальная заглушка.
- Кэш `source: server` доверяется только при живой сессии.
- Paywall: если не вошёл — открывает экран аккаунта и повторяет покупку.
- Шапка: AccountButton («Войти»/email) + чип статуса подписки.
- Адреса серверов: env `PP_AUTH_URL`, `PP_PAYMENTS_URL`; по умолчанию VPS
  (порты 8121/8122). Ошибки — русские.

## Тесты (widget/unit, без сети)
1. license_account_test: регистрация → Free; покупка → Pro; сессия
   восстанавливается; неверный пароль → ошибка; выход снимает Pro;
   сервер недоступен → ошибка входа; офлайн-путь без gateway не изменился.
2. license_ui_test / license_test: прежние (триал, кэш, гейтинг, paywall).

## Критерии приёмки
1. Юнит/widget-тесты зелёные. 2. Без сети код не падает (офлайн-фолбэк).
3. Русские тексты. 4. flutter analyze — чисто.
