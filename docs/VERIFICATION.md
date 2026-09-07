# Верификация «Препресс-Планер»

Документ в двух частях:
- **Часть A** — историческая приёмка MVP по §10 спеки
  `docs/superpowers/specs/2026-09-02-prepress-planner-design.md` (прогоны фазы Ф5,
  среда — Windows-машина разработки, ~2026-09-02/03). Числа в ней относятся к тем
  прогонам и не пересчитывались.
- **Часть B** — дополнительная приёмка работ после MVP (2026-09-07): аккаунты,
  подписка, Web-версия, развёртывание, сборки, документы.

---

## Часть A. Приёмка MVP (историческая)

> Заполнено фактическими выводами команд (аг.14; дата прогона фиксируется в коммите Ф5-14).

### A1. Критерии приёмки (§10)

| № | Критерий | Статус | Команда/факт |
|---|---|---|---|
| 1 | Запуск на iOS/Windows/macOS/Linux; импорт DXF/SVG/PDF локально, AI/CDR/EPS через сервер | ◐ | Flutter 3.47.2, ни одной pub.dev-зависимости; `app/` собирается под все платформы из одного дерева. Локально: DXF/SVG/PDF/AI(PDF-совм.) — `parse_file_test.dart` (7 OK). AI/CDR/EPS — конвертер `services/converter` (7 pytest OK; Inkscape/EPS-ветки подняты). Фактический запуск бинарей под iOS/macOS/Linux в среде приёмки (Windows) не выполнялся — исторический факт MVP (позднее Linux-сборка собрана в WSL и запущена; Web собран и задеплоен — см. Часть B) |
| 2 | Эталонная математика 1:1 (50×30 → 9×5, 112 об., 5040 шт., 34137.6 мм, отходы 26.18 %, 2032.0 мм²/шт) | ✅ | `dart tool/e2e.dart` → «Расход: 9×5, N=5040, оборотов=112, длина=34137.6, отходы=26.18%, на этикетку=2032.0»; `material_test.dart` 9 OK (rapport/row_candidates/col_candidates/count/length/rotation) |
| 3 | Shape-расход по чистой площади; оптимизация 0°/90° с efficiency | ✅ | `shape_test.dart` 7 OK (rect/roundRect/circle/ellipse/polygon + consumption); `optimizer_test.dart` 4 OK (best_variant, rotation_helps_web_narrow, narrow_web_180) |
| 4 | ТЭО: сортамент, машиночасы, скорость, переналадка, рабочее время, оснастка; C_per_1k, экономия, break-even, загрузка смены, чувствительность | ✅ | `economics_test.dart` 6 OK (reference_teo, compare_variants, break_even, catalog_json, rounding). E2E: «ТЭО: costPer1000=704.88, лучший вариант #1 (704.88 ₽/1000)»; `assortment.dart`/`machine.dart`/`teo.dart` в core |
| 5 | PDF ТЭО и XLSX формируются; DXF открываются | ✅ | `reports_test.dart` 5 OK (pdf_structure, xlsx_structure, dxf_write_roundtrip, writers_real_data) — структура проверяется PyMuPDF/zipfile |
| 6 | В `packages/core` нет модулей маски/G-кода | ✅ | grep mask\|gcode\|уф\|уп → 0 (только «управляющие символы» в XML-комментарии) |
| 7 | Триал 15 дней + гейтинг Free/Pro | ✅ | На момент MVP — сервер `services/license` (pytest 10 OK: activate/validate/trial 15 d) + клиент: `license_test.dart` 5 OK + `license_ui_test.dart` 5 OK — bootstrap триала при первом запуске, чип статуса в шапке, paywall, квота Free (1 проект), гейтинг Pro-вкладок/«Перебора вариантов». iOS IAP (StoreKit) — заглушка `purchase()`, реальный IAP вне объёма MVP. **Позднее** аккаунты и подписка переведены на микросервисы `services/auth`+`services/payments` (см. Часть B) |
| 8 | `dart test` (домен), `pytest` (сервисы), `flutter test` зелёные; CI | ✅ | Домен: «ALL PASS (16 files)». pytest: «17 passed» (7 конвертер + 10 лицензии). Flutter: «All tests passed!» (10) + `flutter analyze` «No issues found!». CI: `.github/workflows/ci.yml`, `release.yml` (на момент MVP не прогонялись — репозиторий не был запушен) |

### A2. Фактические выводы прогонов (MVP)

**Домен (16 тест-файлов, ALL PASS)**
```
powershell -File scripts/run_domain_tests.ps1
```
Последний прогон: dxf 2 OK, economics 6 OK, geom_golden 11 OK, geom_smoke 1 OK,
healer 6 OK, inflate 7 OK, manufacturability 10 OK, material 9 OK, optimizer 4 OK,
parse_file 7 OK, pattern 1 OK, pdf 1 OK, reports 5 OK, sample 1 OK, shape 7 OK,
svg 1 OK → «ALL PASS (16 files)».

**E2E-сценарий (эталонные числа 1:1)**
```
dart tool/e2e.dart   (из packages/core)   → E2E OK
1. Парсинг: 3 контуров
2. Анализ: ok=true, issues=1, вердикт: Внимание (1 предупреждений)
3. Лечение: 2 контуров, замкнуто: 2
5. Расход: 9×5, N=5040, оборотов=112, длина=34137.6, отходы=26.18%, на этикетку=2032.0
6. Расход по форме: использовано 7560000.0 мм², отходы 26.18%
7. ТЭО: costPer1000=704.88, лучший вариант #1 (704.88 ₽/1000), экономия 0.0 ₽/1000
```

**Flutter**
```
cd app && flutter analyze   → No issues found!
cd app && flutter test      → All tests passed! (15: 5 widget + 5 license + 5 license_ui)
```

**Сервисы (тогда — конвертер и лицензии)**
```
python -m pytest services/converter/tests services/license/tests -q
→ 17 passed in ~5s (конвертер 7, лицензии 10)
```

### A3. Расхождения, зафиксированные при портировании

1. Контракт 05 п.10: rotated лучше при web=180 у этикетки 60×30 (не 50×30) — проверено python-оракулом.
2. Контракт 04: quadroring.dxf — не массив этикеток (логотип с дублированным эллипсом) — оракул Python.
3. Контракт 07: runTime = length/(speed·1000)/60 ч (м/мин, не м/ч) — формула спеки §7.
4. Триал 15 дней реализован на сервере лицензий и офлайн-заглушкой клиента; iOS IAP — заглушка покупки
   (StoreKit-интеграция требует аккаунта разработчика Apple и вне объёма MVP).

---

## Часть B. Дополнительная приёмка (после MVP, 2026-09-07)

Что добавилось после приёмки MVP: сервисы аккаунтов и подписки (`auth`, `payments`),
восстановление пароля и лимит устройств 1/1, Web-версия и развёртывание на новом
сервере, сборки Windows/Linux/Web, руководство пользователя и аудит безопасности.

| № | Область | Статус | Команда / факт |
|---|---|---|---|
| 1 | Аккаунты и сессии (`services/auth`) | ✅ | Маршруты: `register`/`login`/`logout`/`me`/`devices`/`verify` (внутренний, для payments). Пароли — PBKDF2-SHA256 (200 000 итераций, соль); сессии — opaque-токены 256 бит, в БД только sha256; TTL 720 ч (`PP_TOKEN_TTL`). **Проверка:** pytest `services/auth/tests` — 9 тест-функций (подсчёт `def test_` по коду; ключевые: `test_register_login_me`, `test_device_limit_1_1_evicts_old_session`, `test_logout_revokes_session`, `test_verify_endpoint`, `test_healthz`). **Коммиты:** `2255d2a`, `61b4694` |
| 2 | Сброс пароля и лимит устройств 1/1 | ✅ (с ограничением) | `forgot`/`reset`: одноразовый код 6 цифр, TTL 30 мин (`PP_RESET_TTL`); `logout` реально отзывает сессию; вход с новым `device_id` вытесняет старую сессию (1/1). **Проверка:** pytest auth — `test_forgot_reset_flow`, `test_device_limit_1_1_evicts_old_session`, `test_forgot_for_unknown_email_dev_hint`. **Коммит:** `4f0cd3e`. ⚠️ **Ограничение:** SMTP не настроен (`PP_SMTP_*` пустые) → в dev-режиме код сброса возвращается в ответе `POST /auth/forgot` (`dev_code`) — активная дыра **К-1** в `SECURITY.md`, исправление отложено |
| 3 | Подписка Pro (`services/payments`) | ✅ (заглушка оплаты) | Тарифы `GET /payments/plans`: `month` 990 ₽/30 дн., `year` 9 900 ₽/365 дн.; поток `checkout` → `orders/{id}/confirm` → `subscription`; `webhook` — заглушка. Проверка токена — внутренний `POST {PP_AUTH_URL}/auth/verify`. **Проверка:** pytest `services/payments/tests` — 8 тест-функций по коду (`test_checkout_confirm_subscription_flow`, `test_chained_subscription_extends`, `test_revoked_token_rejected`, `test_webhook_stub`, `test_foreign_order_404` и др.). UI paywall/покупка/восстановление — `app/lib/license/` (`paywall_screen.dart`, `account_screen.dart`; покрытие `app/test/license_account_test.dart`). **Коммиты:** `2255d2a`, `61b4694`. ⚠️ `confirm` метит заказ paid без обращения к провайдеру → Pro фактически бесплатен (**К-4**, `SECURITY.md`) |
| 4 | Web-версия | ✅ | `flutter build web` успешен (артефакт `app/build/web/`); статика задеплоена на сервер — SHA-256 `main.dart.js` совпал с локальной сборкой (наблюдение при развёртывании). Единый origin `http://193.233.193.12:8081`: nginx проксирует `/auth`, `/payments`, `/convert`, `/data`, `/healthz` на имена сервисов (`deploy/nginx/pp-web.conf`) — CORS не нужен. Web-смоук: `app/test/web_boot_smoke_test.dart` (регистрируется только на web-платформе) |
| 5 | Развёртывание на сервере | ✅ | `docker compose up` на **193.233.193.12** (Ubuntu 22.04; стек `/stack`, compose в `/stack/deploy`): контейнеры `deploy-converter-1` (:8120), `deploy-auth-1` (:8121), `deploy-payments-1` (:8122), `deploy-web-1` (nginx, 8081→80). **Пробы:** healthz 200 на 8120/8121/8122 (`curl …/healthz`); web 200 на 8081 (`curl -I http://193.233.193.12:8081/`); `/healthz` через единый origin — 200. E2E-проверка аккаунта и Pro на живом стеке пройдена (регистрация→вход→checkout→confirm→Pro). license-сервис **не развёрнут** |
| 6 | Сборки | ✅ | Windows: `app\build\windows\x64\runner\Release\prepress_planner.exe` (exe собран и присутствует в дереве). Linux: собран в WSL Ubuntu 26.04 (Flutter Linux SDK), запускается ярлыком рабочего стола «Препресс-Планер (Linux).cmd». Web: статика на сервере (см. № 4). macOS/iOS: бинари не собирались (код кроссплатформенный) |
| 7 | Руководство и безопасность | ✅ / ⚠️ | Документы: `РУКОВОДСТВО_ПОЛЬЗОВАТЕЛЯ.md` и `.pdf` (корень, 2026-09-07). Безопасность: `SECURITY.md` — аудит 2026-09-07 по коду, конфигурации и **живому серверу**; зафиксированы К-1…К-5 и план Фаза 1/Фаза 2; **исправления отложены заказчиком** (на 2026-09-07 изменения не внесены) |

Примечания к части B:
- «Статус ✅» означает: факт выполнен и проверен (прогон/наблюдение); для повторной
  проверки использовать команды из сводки ниже.
- «N тест-функций по коду» — подсчёт вхождений `def test_` в
  `services/{auth,payments,…}/tests/*.py` на 2026-09-07 (не результат прогона);
  фактические «passed» фиксировать после запуска pytest.
- Раскрой: список магнитных валов по умолчанию — `88, 96, 120, 176`
  (`app/lib/src/screens/layout_screen.dart`, коммит `448dcba`) — в приёмке MVP этого
  списка ещё не было.

---

## Сводка команд (актуальная, 2026-09-07)

```powershell
# Домен (16 файлов-скриптов)
powershell -File scripts/run_domain_tests.ps1        # исторически ALL PASS

# E2E (эталонные числа; из packages/core)
& '<корень>\.tools\dart-sdk\bin\dart.exe' tool/e2e.dart   # → E2E OK

# Flutter (из app)
cd app
flutter analyze
flutter test

# Сервисы (из корня; python из cam_pipeline\venv)
& 'cam_pipeline\venv\Scripts\python.exe' -m pytest services/converter/tests -q
& 'cam_pipeline\venv\Scripts\python.exe' -m pytest services/auth/tests -q
& 'cam_pipeline\venv\Scripts\python.exe' -m pytest services/payments/tests -q
& 'cam_pipeline\venv\Scripts\python.exe' -m pytest services/license/tests -q

# Прод-стек 193.233.193.12 (чтение/пробы)
ssh -i C:\Users\vkara\.ssh\pp_vps_ed25519 root@193.233.193.12
curl -s http://193.233.193.12:8120/healthz   # конвертер (ожидается 200)
curl -s http://193.233.193.12:8121/healthz   # auth
curl -s http://193.233.193.12:8122/healthz   # payments
curl -sI http://193.233.193.12:8081/         # web (200)
curl -s  http://193.233.193.12:8081/healthz  # единый origin → конвертер
cd /stack/deploy && docker compose ps        # на сервере
```

### Объём тестов по коду (2026-09-07, без запуска)

| Область | Источник подсчёта | По коду |
|---|---|---|
| Домен | `packages/core/test/*.dart` (файлы-скрипты) | 16 файлов |
| Flutter | `app/test/*.dart` | 11 файлов; 38 вызовов `test()`/`testWidgets()` (регистрация web-смоука условная — фактическое число «passed» только после прогона) |
| Конвертер | `def test_` в `services/converter/tests/` | 11 (test_convert.py 7 + test_jobs.py 4) |
| Auth | `def test_` в `services/auth/tests/` | 9 |
| Payments | `def test_` в `services/payments/tests/` | 8 |
| License | `def test_` в `services/license/tests/` | 10 |
