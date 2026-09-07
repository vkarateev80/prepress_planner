# Комплект развёртывания «Препресс-Планер» для НОВОГО сервера

Единый стек на одном Ubuntu-сервере: конвертер, авторизация, оплата и
**web-версия** приложения (единый origin через nginx — без CORS).

| Компонент | Внутри сети | Снаружи |
|---|---|---|
| converter (AI/CDR/EPS → SVG) | `converter:8120` | `:8120` |
| auth (аккаунты, сессии, лимит 1/1, сброс пароля) | `auth:8121` | `:8121` |
| payments (подписка, проверка токена через auth) | `payments:8122` | `:8122` |
| web (Flutter Web + прокси `/auth /payments /convert /data /healthz`) | `web:80` | **`:8081`** |

## Содержимое
- `docker-compose.yml` — полный стек (4 сервиса, одна сеть, именованные тома
  `converter-data`, `auth-data`, `payments-data`, healthcheck'и);
- `nginx/pp-web.conf` — конфиг nginx: статика SPA + прокси по именам сервисов
  (`/auth` → auth, `/payments` → payments, `/convert`/`/data`/`/healthz` →
  converter), `client_max_body_size 64m`;
- `.env.example` — шаблон переменных (`PP_AUTH_SECRET`, SMTP);
- `install_new_server.sh` — первичная настройка нового Ubuntu (root);
- `web/` — сюда кладётся статика `flutter build web` (собирается скриптом);
- `build_bundle.ps1` / `build_bundle.sh` — сборка единого архива
  `pp-new-server-stack.tar.gz`.

## Как развернуть новый сервер

**1) Собрать web-версию и бандл (на машине разработки):**
```powershell
# из app/:  flutter build web  (результат в app/build/web)
# из корня репозитория:
powershell -ExecutionPolicy Bypass -File deploy\build_bundle.ps1
# Linux/macOS: bash deploy/build_bundle.sh
```
Получится `pp-new-server-stack.tar.gz` в корне репозитория.

**2) Загрузить и распаковать на новом сервере:**
```bash
scp pp-new-server-stack.tar.gz root@<новый-IP>:/
ssh root@<новый-IP>
tar xzf pp-new-server-stack.tar.gz     # появится stack/{deploy,services}
cd stack/deploy && bash install_new_server.sh
```
Скрипт (идемпотентный, от root): ставит Docker + compose (если отсутствуют),
создаёт `.env`, если его нет — с `PP_AUTH_SECRET` из `openssl rand -hex 32`
(остальные `PP_SMTP_*` — пустые), поднимает стек (`docker compose up -d
--build`) и ждёт здоровье всех сервисов (пробы 8120/8121/8122/8081, до 150 с).
Имя compose-проекта — имя каталога (`deploy`), поэтому контейнеры называются
`deploy-{converter,auth,payments,web}-1`.

**3) Открыть:**
- Web: `http://<новый-IP>:8081`
- Прямые порты сервисов опубликованы для desktop-клиента (8120–8122).

## Текущий прод (2026-09-07)

Состояние на дату (подробности и риски — в корневом `SECURITY.md`):

- Сервер **193.233.193.12**, Ubuntu 22.04; стек развёрнут в **`/stack`**
  (бандл распакован так, что compose-файл — `/stack/deploy/docker-compose.yml`).
- Контейнеры `deploy-{converter,auth,payments,web}-1` — все healthy
  (`docker compose ps` в `/stack/deploy`).
- Web-версия: **http://193.233.193.12:8081** (nginx единого origin).
- Прямые порты **8120/8121/8122 открыты наружу** — desktop-клиент ходит на
  них напрямую (дефолты env в `app/`).
- `.env` на сервере сгенерирован `install_new_server.sh`: `PP_AUTH_SECRET` —
  64 hex-символа, **`PP_SMTP_*` пустые** → `POST /auth/forgot` работает в
  dev-режиме (код сброса возвращается в ответе — см. `SECURITY.md` К-1).
- **Firewall/ufw НЕ настроен, TLS нет** (весь трафик по http); права: `.env` —
  644, каталоги `/stack` — 777. Рекомендации по устранению — `SECURITY.md`
  (разделы 1–2 и план, фаза 1–2).

## Адреса сервисов в клиенте

- **Desktop:** адреса задаются env при запуске приложения —
  `PP_CONVERTER_URL`, `PP_AUTH_URL`, `PP_PAYMENTS_URL`. Дефолты в коде
  указывают на текущий прод: `http://193.233.193.12:8120` (converter),
  `…:8121` (auth), `…:8122` (payments) — см.
  `app/lib/src/converter/converter_api.dart`,
  `app/lib/src/converter/converter_server.dart`, `app/lib/license/account_client.dart`.
- **Web:** адресов в коде нет вовсе — браузер ходит относительными путями
  (`/auth`, `/payments`, `/convert`, `/data`) на единый origin `:8081`, их
  проксирует nginx.

После развёртывания на **новом** сервере замените дефолты/переменные на его
адрес (см. раздел выше; в `SECURITY.md`, фаза 1, планируется перевод десктопа
на единый origin `:8081`).

## Перенос данных (если нужно)
Сервисы хранят данные в именованных томах compose (`converter-data`,
`auth-data`, `payments-data`): аккаунты, сессии, заказы, история конвертации.
Экспорт и импорт — штатными средствами Docker (точные имена томов — по
`docker volume ls`, обычно `<проект>_converter-data` и т.п.), например:
```bash
# на старом сервере, в каталоге стека:
#   docker volume ls                                  # найти имена томов
#   docker run --rm -v <проект>_converter-data:/data -v $PWD:/backup \
#     alpine tar czf /backup/converter.tgz -C /data .
#   …аналогично auth-data, payments-data;
# на новом: распаковать в те же тома (<новый-проект>_auth-data и т.д.) перед up.
```
Настройка SMTP в `.env` — по желанию (без неё код сброса пароля работает в
dev-режиме: возвращается в ответе `/auth/forgot`).

## Проверка после установки
```bash
docker compose ps                                  # все 4 контейнера healthy
curl -s http://127.0.0.1:8120/healthz              # конвертер (движки + job_store)
curl -s http://127.0.0.1:8121/healthz              # auth
curl -s http://127.0.0.1:8122/healthz              # payments
curl -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8081/            # 200, index.html
curl -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8081/healthz     # конвертер через web
curl -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8081/auth/devices    # 401 (нужен токен)
curl -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8081/payments/subscription # 401
docker compose logs -f                             # логи при проблемах
```
