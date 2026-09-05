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
- `docker-compose.yml` — полный стек (4 сервиса, одна сеть, томá данных);
- `nginx/pp-web.conf` — конфиг nginx (прокси по именам сервисов);
- `.env.example` — шаблон переменных (`PP_AUTH_SECRET`, SMTP);
- `install_new_server.sh` — первичная настройка нового Ubuntu (root);
- `web/` — сюда кладётся статика `flutter build web` (собирается скриптом);
- `build_bundle.ps1` / `build_bundle.sh` — сборка единого архива.

## Как развернуть новый сервер

**1) Собрать web-версию и бандл (на машине разработки):**
```powershell
# из app/:  flutter build web
powershell -ExecutionPolicy Bypass -File deploy\build_bundle.ps1
```
Получится `pp-new-server-stack.tar.gz` в корне репозитория.

**2) Загрузить и распаковать на новом сервере:**
```bash
scp pp-new-server-stack.tar.gz root@<новый-IP>:/
ssh root@<новый-IP>
tar xzf pp-new-server-stack.tar.gz
cd stack/deploy && bash install_new_server.sh
```
Скрипт: ставит Docker + compose (при отсутствии), генерирует `.env`
(секрет `PP_AUTH_SECRET` случайный), поднимает стек (`docker compose up -d
--build`) и ждёт здоровье всех сервисов (контроль на 8120/8121/8122/8081).

**3) Открыть:**
- Web: `http://<новый-IP>:8081`
- Прямые порты сервисов опубликованы для desktop-клиента (8120–8122).

## Перенос данных (если нужно)
Сервисы хранят данные в томах `converter-data`, `auth-data`, `payments-data`
(аккаунты, сессии, заказы, история конвертации). Перенос с текущего сервера:
```bash
# на старом сервере (директории /opt/pp-converter и /opt/pp-services):
#   docker run --rm -v converter-data:/data -v $PWD:/backup alpine tar czf /backup/converter.tgz -C /data .
# …аналогично auth-data, payments-data; на новом: распаковать в те же тома.
```
Настройка SMTP в `.env` на новом сервере — по желанию (без неё код сброса
пароля работает в dev-режиме: возвращается в ответе `/auth/forgot`).

## ВАЖНО: адреса в desktop-клиенте
Десктопное приложение по умолчанию обращается к старому серверу
(`http://193.233.193.12:8120/8121/8122` — IP в коде скрыт из UI, но зашит в
дефолты). После переезда на новый сервер:
- либо задайте переменные окружения при запуске приложения:
  `PP_CONVERTER_URL=http://<новый-IP>:8120`, `PP_AUTH_URL=…:8121`,
  `PP_PAYMENTS_URL=…:8122`;
- либо (рекомендуется) обновите дефолты в
  `app/lib/src/converter/converter_api.dart`,
  `app/lib/src/converter/converter_server.dart`,
  `app/lib/license/account_client.dart` (замените старый IP) и пересоберите
  desktop-версию. В web-версии адресов нет вообще — она работает через
  единый origin `:8081`.

## Проверка после установки
```bash
curl http://127.0.0.1:8081/            # index.html (200)
curl http://127.0.0.1:8081/healthz     # конвертер: {"status":"ok",…}
curl -o /dev/null -w '%{http_code}' http://127.0.0.1:8081/auth/devices    # 401
curl -o /dev/null -w '%{http_code}' http://127.0.0.1:8081/payments/subscription  # 401
docker compose ps
```
