# 06. Развёртывание и эксплуатация (Deploy & Ops)

> **Статус: актуален на 2026-09-07 (HEAD bed533e)**
> Источники факта: `deploy/README.md`, `deploy/docker-compose.yml`, `deploy/nginx/pp-web.conf`,
> `deploy/install_new_server.sh`, `deploy/build_bundle.{ps1,sh}`, `deploy/.env.example`,
> `SECURITY.md`, `docs/HANDOFF.md` §6, `docs/VERIFICATION.md` (часть B).
> Все команды ниже — из перечисленных файлов. Там, где процедуры в репозитории нет, стоит явная
> пометка **«требует проверки/описать»** — додумывать нельзя.
> Прод: сервер **193.233.193.12** (Ubuntu 22.04, Docker + compose), стек в `/stack`
> (`/stack/deploy` + `/stack/services`), контейнеры `deploy-{converter,auth,payments,web}-1`
> (`deploy/README.md:54-70`, `docs/HANDOFF.md:223-244`).

---

## 1. Схема прод-развёртывания

```
                  Интернет (весь трафик по http — TLS нет, SECURITY.md К-3)
        ┌──────────────┬──────────────┬──────────────────────┐
   :8120 (прямой)  :8121 (прямой)  :8122 (прямой)        :8081 (web, единый origin)
        ▼              ▼              ▼                      ▼
  ┌───────────┐  ┌───────────┐  ┌────────────┐   ┌────────────────────────────────┐
  │ converter │  │   auth    │  │  payments  │   │ web = nginx:alpine             │
  │  :8120    │  │  :8121    │  │   :8122    │   │ root /usr/share/nginx/html     │
  │ uvicorn   │  │  SQLite   │  │  SQLite    │   │ (bind-mount ./web, ro)         │
  │ --workers2│  │ auth.db   │  │ payments.db│   │ + прокси по именам сервисов:   │
  │ Inkscape+ │  │ PBKDF2,   │  │ токен →    │   │ /auth /payments → auth/payments │
  │ Ghostscr. │  │ сессии 1/1│  │ auth/verify│   │ /convert /data /healthz →       │
  │ job_store │  │           │  │            │   │      converter:8120             │
  │ = file    │  │           │  │            │   │  /  try_files → index.html      │
  └─────┬─────┘  └─────┬─────┘  └─────┬──────┘   └──────────────┬─────────────────┘
        ▼              ▼              ▼                         ▼
  deploy_converter-data  deploy_auth-data  deploy_payments-data
  (именованные тома Docker; внутри сети compose — по именам сервисов, без CORS:
   deploy/docker-compose.yml:13-14, deploy/nginx/pp-web.conf:1-2)
```

| Что | Файл:строка |
|---|---|
| Публикация портов 8120/8121/8122 (прямые, для desktop) | `deploy/docker-compose.yml:19-20,39-40,66-67` |
| Публикация web `8081:80` | `deploy/docker-compose.yml:84-85` |
| Прокси nginx по именам сервисов | `deploy/nginx/pp-web.conf:16-38` |
| SPA-фолбэк `/` → `index.html`; лимит тела 64 МБ | `deploy/nginx/pp-web.conf:11-13,40` |
| Тома данных; имя тома = `<проект>_<том>`, проект = имя каталога (`deploy`) | `deploy/docker-compose.yml:95-98`, `deploy/README.md:47-48,88-92` |
| Внутренний адрес payments → auth (`http://auth:8121`) | `deploy/docker-compose.yml:70` |

Фактические имена томов на проде: `deploy_converter-data`, `deploy_auth-data`,
`deploy_payments-data` (вывод из `deploy/README.md:88-92` + `docs/HANDOFF.md:225-234`); проверять
командой `docker volume ls` (`deploy/README.md:95`).

---

## 2. Состав комплекта `deploy/`

| Файл | Назначение | Ссылка |
|---|---|---|
| `docker-compose.yml` | Стек: 4 сервиса, одна сеть, healthcheck'и, `restart: unless-stopped` | `deploy/docker-compose.yml:1-98` |
| `nginx/pp-web.conf` | nginx: статика SPA + прокси `/auth`, `/payments`, `/convert`, `/data`, `/healthz` | `deploy/nginx/pp-web.conf:1-41` |
| `install_new_server.sh` | Первичная настройка нового Ubuntu (root): Docker, `.env`, `up -d --build`, health-цикл | `deploy/install_new_server.sh:1-70` |
| `build_bundle.ps1` / `build_bundle.sh` | Сборка `pp-new-server-stack.tar.gz` (Windows / Linux-macOS) | `deploy/build_bundle.ps1:1-38`, `deploy/build_bundle.sh:1-36` |
| `.env.example` | Шаблон переменных: `PP_AUTH_SECRET`, `PP_SMTP_*` | `deploy/.env.example:1-11` |
| `README.md` | Инструкция развёртывания, описание текущего прода, проверки | `deploy/README.md:1-115` |
| `deploy/web/` | Статика `flutter build web` (кладёт сборщик бандла) | `deploy/README.md:21`, `deploy/build_bundle.ps1:19` |
| `services/docker-compose.yml` | Альтернативный compose без web-сервиса (3 сервиса) | `services/docker-compose.yml:1-81` |

Содержимое бандла: `stack/deploy/*` + `stack/deploy/web/` + `stack/services/{converter,auth,payments}`
(`deploy/build_bundle.ps1:16-22`, `deploy/build_bundle.sh:25-28`), с чисткой `__pycache__`,
`.pytest_cache`, `data`, `*.pyc`, `*.db` (`deploy/build_bundle.ps1:24-29`,
`deploy/build_bundle.sh:31-32`). Сервиса `license` в бандле нет (`services/license/README.md:7-15`).

---

## 3. Процедуры

### 3.1. Первичная установка на новый сервер

```bash
# 1) На машине разработки: собрать web-статику (из app/: flutter build web → app/build/web) и бандл
powershell -ExecutionPolicy Bypass -File deploy\build_bundle.ps1     # Windows  (deploy/README.md:31)
bash deploy/build_bundle.sh                                          # Linux    (deploy/README.md:32)

# 2) Загрузить и распаковать на сервере (deploy/README.md:38-41)
scp pp-new-server-stack.tar.gz root@<новый-IP>:/
ssh root@<новый-IP>
tar xzf pp-new-server-stack.tar.gz      # появится stack/{deploy,services}
cd stack/deploy && bash install_new_server.sh
```

`install_new_server.sh` идемпотентен и запускается от root (`deploy/install_new_server.sh:11-17`):
проверяет root → ставит Docker (`get.docker.com`) и при необходимости `docker-compose-plugin`
(`:19-29`) → создаёт `.env`, если его нет: `PP_AUTH_SECRET` из `openssl rand -hex 32`, `PP_SMTP_*` пустые (`:31-47`) → `docker compose up -d --build` (`:49-50`) → ждёт 200 от 8120/8121/8122/8081 до 150 с и печатает `docker compose ps` (`:52-68`). Если Docker ставится на сервер с данными — сначала бэкап томов (§3.5).

### 3.2. Обновление кода и пересборка

На проде `/stack` — не git-репозиторий, а распакованный бандл (`docs/HANDOFF.md:223-227`),
поэтому штатный путь обновления — тот же бандл:

```bash
# локально
powershell -ExecutionPolicy Bypass -File deploy\build_bundle.ps1     # deploy/README.md:31
scp pp-new-server-stack.tar.gz root@193.233.193.12:/                  # deploy/README.md:38
# на сервере
cd / && tar xzf pp-new-server-stack.tar.gz                            # deploy/README.md:40
cd /stack/deploy && bash install_new_server.sh                         # deploy/README.md:41
```

`.env` при повторном запуске **не перезаписывается** (`deploy/install_new_server.sh:45-47`), поэтому `PP_AUTH_SECRET` и SMTP-настройки сохраняются. Пересборка — `docker compose up -d --build` внутри скрипта (`deploy/install_new_server.sh:50`). Пересборка только изменённого сервиса в комплекте не описана — **требует проверки/описать**.

### 3.3. Обновление только web-статики

Каталог статики смонтирован как bind-mount только для чтения (`deploy/docker-compose.yml:87`), поэтому замена файлов в `deploy/web` не требует пересборки образа. Точная серверная процедура (что заменить и что выполнить после) в репозитории **не зафиксирована — требует проверки/описать**. Подтверждено на дату: полный путь через бандл (§3.2) и контроль целостности сравнением SHA-256 `main.dart.js` с локальной сборкой (`docs/VERIFICATION.md:85`). Любые изменения на живом сервере согласуются с заказчиком: действует установка «пока ничего не менять» (`SECURITY.md:7-9`, `docs/HANDOFF.md:236-239`).

### 3.4. Проверка здоровья

```bash
cd /stack/deploy
docker compose ps                                  # все 4 контейнера healthy   (deploy/README.md:106)
curl -s http://127.0.0.1:8120/healthz              # конвертер (движки + job_store)
curl -s http://127.0.0.1:8121/healthz              # auth
curl -s http://127.0.0.1:8122/healthz              # payments
curl -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8081/            # 200, index.html
curl -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8081/healthz     # конвертер через web
curl -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8081/auth/devices        # 401
curl -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8081/payments/subscription # 401
docker compose logs -f                             # логи при проблемах        (deploy/README.md:114)
```

Тело ответов для интерпретации: `:8120/healthz` → `{"status":"ok","engines":{"inkscape":bool,"ghostscript":bool},"job_store":"file"}` (`services/converter/converter_app/main.py:79-89`); `:8121/healthz` → `{"status":"ok","service":"auth","db":…,"sessions":"server-side","device_limit":1,"smtp":bool,…}` (`services/auth/auth_app/main.py:430-435`); `:8081/healthz` — тот же конвертерный через nginx (`deploy/nginx/pp-web.conf:16-19`). Healthcheck'и compose: интервал 15 с, timeout 5 с, retries 5, `start_period` 10 с (converter) и 5 с (auth/payments) — `deploy/docker-compose.yml:27-33,54-60,73-79`. У сервиса `web` healthcheck'а нет (`deploy/docker-compose.yml:82-93`).

### 3.5. Бэкап и восстановление томов

Точные команды — `deploy/README.md:88-100` (даны закомментированными):

```bash
# на текущем сервере, в каталоге стека:
docker volume ls                                   # найти имена томов (deploy_*_data)
docker run --rm -v deploy_converter-data:/data -v $PWD:/backup \
  alpine tar czf /backup/converter.tgz -C /data .
#   …аналогично auth-data, payments-data

# на новом сервере: распаковать в те же тома ПЕРЕД `up`
docker run --rm -v deploy_auth-data:/data -v $PWD:/backup \
  alpine tar xzf /backup/auth.tgz -C /data
```

Внутри томов: аккаунты/сессии (`auth.db`), заказы/подписки (`payments.db`), история и результаты конвертации (`deploy/README.md:88-91`). Открытые вопросы: процедура «остановить → восстановить → поднять» в репозитории отсутствует, регламента бэкапов (расписание, хранение, проверка восстановления) нет — **требует проверки/описать** (см. §7, `09_roadmap.md` п. 2.9).

### 3.6. Откат версии

Реестра образов с версионными тегами нет — в compose фиксированы `pp-*:latest`
(`deploy/docker-compose.yml:18,38,65`), поэтому откат = пересборка из предыдущего коммита:

```bash
# локально
git -c safe.directory='*' checkout <предыдущий-коммит>   # приём для Windows: docs/HANDOFF.md:254
powershell -ExecutionPolicy Bypass -File deploy\build_bundle.ps1
scp pp-new-server-stack.tar.gz root@193.233.193.12:/
# на сервере
cd / && tar xzf pp-new-server-stack.tar.gz && cd /stack/deploy && bash install_new_server.sh
```

Данные при откате сохраняются: тома именованные (`deploy/docker-compose.yml:95-98`). Схемы БД
создаются сервисами сами (`services/auth/README.md:12`, `services/payments/README.md:23`);
совместимость схем между версиями **требует проверки**.

---

## 4. Переменные окружения и секреты

| Переменная | Где задаётся (файл:строка) | Значение/смысл |
|---|---|---|
| `PP_AUTH_SECRET` | `deploy/docker-compose.yml:43`, `deploy/.env.example:1-3`, `deploy/install_new_server.sh:33-36` | Обяз. для старта auth; на проде — 64 hex (`openssl rand -hex 32`); для подписи **не используется** (`services/auth/README.md:47`) |
| `PP_SMTP_HOST/PORT/USER/PASSWORD/FROM` | `deploy/docker-compose.yml:47-51`, `deploy/.env.example:5-11` | Почта для forgot; на проде пустые → dev-режим с `dev_code` (`deploy/README.md:65-67`, К-1) |
| `PP_SMTP_SSL` | `services/auth/README.md:52` | `1` = TLS сразу (465); в compose не проброшена — **требует проверки/описать** |
| `PP_TOKEN_TTL` / `PP_RESET_TTL` | `deploy/docker-compose.yml:44-45` | 720 ч (30 дней) / 30 мин |
| `PP_DATA_DIR`, `PP_JOB_STORE`, `PP_JOB_TTL_HOURS` | `deploy/docker-compose.yml:22-24,42,69` | Каталоги данных в томах, file-очередь, TTL 24 ч |
| `PP_AUTH_URL` | `deploy/docker-compose.yml:70` | Внутренний адрес auth для payments |
| `PP_MAX_MB` | в compose не проброшена; дефолт 50 (`services/converter/README.md:90`) | Лимит файла, проверяется ПОСЛЕ записи (В-1) |
| `PP_PUBLIC_BASE` | не проброшена (`services/payments/README.md:48`) | Публичный адрес для `url` оплаты; пусто → `url: null` |
| `PP_CONVERTER_URL`, `PP_AUTH_URL`, `PP_PAYMENTS_URL` | клиент desktop: `app/lib/src/converter/converter_api.dart:56-59`, `app/lib/license/account_client.dart:201-202`, `docs/HANDOFF.md:200-202` | Адреса сервисов у клиента; дефолты ведут на `:8120-8122` |

Секреты: реальный `.env` в git не попадает — правила `.gitignore:51-53` (`.env`, `**/.env`),
в репозитории только `deploy/.env.example` (`deploy/README.md:19`, `docs/HANDOFF.md:272-273`).
Временные askpass/pw-файлы удалять, аудит-скрипты на сервере не оставлять (`SECURITY.md:66-70`).
Ротация секретов — `docs/specs/08_security.md` §7.

---

## 5. Права и доступы (факт и цель)

| Объект | Сейчас (2026-09-07) | Цель (Фаза 1, `SECURITY.md:56`) |
|---|---|---|
| `/stack`, `/stack/deploy`, `/stack/deploy/web` | `777` (`SECURITY.md:29`, `deploy/README.md:68-69`) | `755` |
| `/stack/deploy/.env` | `644`, мир-читаемый (`SECURITY.md:29`) | `600` |
| Контейнеры | работают от root (`SECURITY.md:26`) | не-root + лимиты |
| Пользователи ОС | только root (`SECURITY.md:29`) | отдельный пользователь (Фаза 2) |
| ufw/firewall | выключен, iptables ACCEPT (`SECURITY.md:19`) | только 22 и 8081 после перевода десктопа на `:8081` (`SECURITY.md:55`) |
| SSH | `PermitRootLogin yes` + `PasswordAuthentication yes`, брутфорс (`SECURITY.md:18`) | `prohibit-password` + ключ `pp_vps_ed25519` + fail2ban (`SECURITY.md:54`) |

Команды Фазы 1 (`chmod 755 …`, `chmod 600 …`, `ufw allow 22,8081` + `ufw enable`, правка
`/etc/ssh/sshd_config`, fail2ban) — из плана `SECURITY.md:52-57`; выполнять только по согласованию
(на дату: «пока ничего не менять», `SECURITY.md:7-9`).
Доступ на дату: `ssh -i C:\Users\vkara\.ssh\pp_vps_ed25519 root@193.233.193.12`
(`docs/VERIFICATION.md:123`, `docs/HANDOFF.md:235-239`).

---

## 6. Мониторинг и логи

| Что есть | Как пользоваться | Ссылка |
|---|---|---|
| `docker compose ps` | статус healthy всех 4 контейнеров | `deploy/README.md:106` |
| `docker compose logs -f` | поток логов всех сервисов | `deploy/README.md:114` |
| Healthcheck'и compose | автоматический контроль состояния | `deploy/docker-compose.yml:27-33,54-60,73-79` |
| Health-цикл установки | 30 попыток × 5 с, печать `probe: converter=… auth=… payments=… web=…` | `deploy/install_new_server.sh:52-68` |
| `/healthz` auth | поле `smtp: bool` — видно, включён ли реальный сброс пароля | `services/auth/auth_app/main.py:430-435` |
| Логи клиента | `AppLog` + окно журнала в приложении | `docs/HANDOFF.md:45-47` |

Чего нет: внешнего мониторинга, алертинга, централизованного сбора и ротации логов, метрик и SLO —
упоминаний таких систем в репозитории нет (**требует проверки/описать**; направление — `09_roadmap.md` п. 2.9).
Нельзя логировать: пароли, reset-коды, токены сессий, содержимое `.env` и SMTP-пароль
(`SECURITY.md:47`; требования — `08_security.md` §5). Тексты исключений конвертера сейчас утекают
клиенту (`SECURITY.md:39`) — отдельный долг.

---

## 7. Обязательные работы перед «боевым» режимом

| # | Работа | Почему | Ссылка |
|---|---|---|---|
| 1 | Код-фикс `/auth/forgot`: не возвращать код вне dev-флага (503 без SMTP) | К-1: захват любого аккаунта | `SECURITY.md:17,53` |
| 2 | SSH-харденинг + fail2ban + смена пароля root | К-2: активный брутфорс | `SECURITY.md:18,54` |
| 3 | ufw: наружу только 22 и 8081 | К-3: 8120–8122 открыты в интернет | `SECURITY.md:19,55` |
| 4 | Перевод desktop-дефолтов на единый origin `:8081` | предусловие для п. 3 | `SECURITY.md:57` |
| 5 | Права `755`/`600`, не-root контейнеры | В-2, В-5 | `SECURITY.md:26,29,56` |
| 6 | Rate limiting в auth/payments/converter | К-5 | `SECURITY.md:21` |
| 7 | Авторизация и лимиты конвертера; закрыть `work/` и `jobs/*.json` | В-1: DoS, утечка исходников | `SECURITY.md:25` |
| 8 | Реальный платёжный провайдер + подпись вебхуков | К-4: Pro бесплатно | `SECURITY.md:20,62` |
| 9 | SMTP или явное отключение сброса; домен + TLS | К-1, К-3 (Фаза 2) | `SECURITY.md:60-61` |
| 10 | `apt-get upgrade` (317 пакетов), пиннинг зависимостей | В-5, нерепроизводимость | `SECURITY.md:29,64` |
| 11 | Мониторинг/алертинг и регламент бэкапов с проверкой восстановления | отсутствуют (§3.5, §6) | `09_roadmap.md` п. 2.9 |

Полные формулировки — `SECURITY.md:50-64`; нормативные требования — `docs/specs/08_security.md`.

---

## 8. Чек-лист дежурного (после любого деплоя / перед выдачей наружу)

1. `cd /stack/deploy && docker compose ps` — 4 контейнера `Up (healthy)` (`deploy/README.md:106`).
2. `curl -s http://127.0.0.1:8120/healthz` → `"status":"ok"`; `engines.inkscape/ghostscript` — по ожиданию.
3. `curl -s http://127.0.0.1:8121/healthz` → `"status":"ok"`; при `"smtp":false` помнить про К-1.
4. `curl -s http://127.0.0.1:8122/healthz` → `"status":"ok"`.
5. `http://127.0.0.1:8081/` → `200` (index.html); `http://127.0.0.1:8081/healthz` → `200`.
6. `…/8081/auth/devices` → `401`; `…/8081/payments/subscription` → `401`.
7. SHA-256 задеплоенной статики сверен с локальной сборкой (приём `docs/VERIFICATION.md:85`).
8. `docker compose logs --tail=200` — нет трейсбеков и ошибок конвертации.
9. `.env` не изменился, `PP_AUTH_SECRET` не пересоздан (`deploy/install_new_server.sh:45-47`).
10. Есть актуальный бэкап томов `auth.db`/`payments.db` (§3.5).
11. Свободное место на диске проверено (тома конвертера чистятся по `PP_JOB_TTL_HOURS=24` —
    `deploy/docker-compose.yml:24`; команда контроля в репозитории не зафиксирована — **требует проверки**).
12. Факт деплоя записан в журнал проекта: коммит, время, что менялось (`docs/HANDOFF.md:265-269`).
13. При отклонении — не «править руками»: снять состояние (`ps`, `logs`), откатиться по §3.6,
    согласовать с заказчиком (`docs/HANDOFF.md:236-239`).
