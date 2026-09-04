# Агент 12 — Аккаунт и подписка в приложении (app/lib/license/)

## Роль (Ф4)
Клиентская часть монетизации в Flutter-приложении: вход/регистрация по
email+пароль (с device_id = machine_id), сброс пароля, лимит устройств 1/1,
подписка Pro с микросервиса оплаты, офлайн-фолбэк, гейтинг фич, paywall.

## Файлы
```
app/lib/license/account_client.dart       // AccountGateway (интерфейс) + HTTP:
                                          // AuthApi/PaymentsApi, SessionStore,
                                          // forgot/reset/devices
app/lib/license/account_screen.dart       // вход/регистрация/«Забыли пароль?»/
                                          // профиль («Устройства: 1/1»)
app/lib/license/license_client.dart       // офлайн-заглушка (триал 15 дней)
app/lib/license/license_controller.dart   // сессия, device_id, синхронизация
                                          // подписки, forgot/reset, покупка
app/lib/license/paywall_screen.dart
app/test/license_account_test.dart
```

## Логика
- Login/register передают `device_id` (MachineId из state/machine_id.txt).
- AccountGateway (фейк в тестах / HTTP на VPS 8121/8122).
- LicenseController:
  - `init()`: восстановление сессии → кэш → сервер; иначе офлайн-триал.
  - `login/register`: gateway (с device_id) → сессия → подписка с сервера.
  - `forgot(email)` → `{error?, devCode?}`; `reset(email, code, pass)`.
  - `devices()` → список сессий (лимит 1/1, метка current).
  - `purchase`: заказ в payments + тестовое подтверждение → refresh.
  - `logout`: серверный отзыв сессии + удаление локальной; серверный Pro не
    переносится в офлайн.
  - Кэш source=server доверяется только при живой сессии.
- UI: «Забыли пароль?» на экране входа; в профиле «Устройства: 1/1» и список
  (текущее отмечено); подсказка «вход с другого устройства вытеснит это».
- Адреса: env PP_AUTH_URL/PP_PAYMENTS_URL; по умолчанию VPS (8121/8122).

## Тесты (unit/widget, без сети)
1. license_account_test: регистрация/вход с device_id, покупка → Pro,
   восстановление сессии; forgot+reset (dev-код, старый пароль не подходит);
   неверный код; выход снимает Pro; сервер недоступен; офлайн без gateway.
2. license_ui_test/license_test: прежние (триал, кэш, гейтинг, paywall).

## Критерии приёмки
1. Юнит/widget-тесты зелёные; flutter analyze — чисто.
2. Без сети код не падает (офлайн-фолбэк). 3. Русские тексты.
