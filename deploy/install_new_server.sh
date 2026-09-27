#!/bin/bash
# =============================================================
#  Первичная настройка сервера «Препресс-Планер» (SaaS-стек)
#  Запуск от root:  bash install_new_server.sh
#
#  Структура (из бандла pp-new-server-stack.tar.gz):
#    <root>/deploy/{docker-compose.yml, nginx/, .env.example, …}
#    <root>/deploy/web/               — статика flutter build web
#    <root>/services/{api,converter,auth,payments,domain-worker}/
#    <root>/packages/core/ + <root>/Dockerfile.domain-worker
#
#  Скрипт идемпотентен: повторный запуск пересобирает/перезапускает.
#  Порты наружу: только nginx (80/443); внутренние сервисы не публикуются
#  (ADR-6). Порт 80 должен быть свободен (nginx + ACME HTTP-01).
# =============================================================
set -e
cd "$(dirname "$0")"

echo "[1/5] root/права"
if [ "$(id -u)" -ne 0 ]; then echo "Запустите от root: sudo bash install_new_server.sh"; exit 1; fi

echo "[2/5] Docker + compose"
if ! command -v docker >/dev/null 2>&1; then
  curl -fsSL https://get.docker.com | sh
fi
if ! docker compose version >/dev/null 2>&1; then
  echo "compose-плагин не найден — ставлю docker-compose-plugin"
  apt-get update -qq
  apt-get install -y -qq docker-compose-plugin
fi
systemctl enable --now docker >/dev/null 2>&1 || true
docker compose version

echo "[3/5] .env (секреты)"
if [ ! -f .env ]; then
  cat > .env <<EOF
# Сгенерирован install_new_server.sh
PP_AUTH_SECRET=${PP_AUTH_SECRET:-$(openssl rand -hex 32)}
PP_DB_PASSWORD=${PP_DB_PASSWORD:-$(openssl rand -hex 24)}
PP_PUBLIC_BASE=${PP_PUBLIC_BASE:-https://prepressplan.ru}

PP_SMTP_HOST=
PP_SMTP_PORT=587
PP_SMTP_USER=
PP_SMTP_PASSWORD=
PP_SMTP_FROM=
EOF
  echo ".env создан: PP_AUTH_SECRET, PP_DB_PASSWORD, PP_PUBLIC_BASE."
  echo "Почта (PP_SMTP_*), ключи ЮKassa и PP_OFFSITE_* — заполните вручную."
else
  echo ".env уже есть — оставляю."
fi

echo "[3.5/5] TLS-сертификат (dev-самоподпись; прод — get_prod_certs.sh)"
if [ ! -f nginx/certs/fullchain.pem ] || [ ! -f nginx/certs/privkey.pem ]; then
  PP_TLS_CN="${PP_TLS_CN:-prepressplan.ru}" bash nginx/gen_dev_certs.sh
else
  echo "Сертификаты уже есть — не трогаю."
fi

echo "[4/5] docker compose up -d --build"
docker compose up -d --build

echo "[5/5] ожидание здоровья (edge https://127.0.0.1)"
OK=""
for i in $(seq 1 60); do
  HZ=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 3 https://127.0.0.1/healthz || true)
  SPA=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 3 https://127.0.0.1/ || true)
  AUTH=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 3 https://127.0.0.1/auth/devices || true)
  echo "  probe: healthz=$HZ spa=$SPA auth=$AUTH"
  if [ "$HZ" = "200" ] && [ "$SPA" = "200" ] && [ "$AUTH" = "401" ]; then
    OK=1
    break
  fi
  sleep 5
done

docker compose ps
if [ -n "$OK" ]; then
  echo
  echo "СТЕК РАБОТАЕТ:"
  echo "  https://<домен>/          (SPA; до смены DNS — https://<IP>/, браузер ругается на dev-сертификат)"
  echo "  https://<домен>/legal/    (реквизиты/оферта/тарифы)"
  echo "  Проверка: curl -sk https://127.0.0.1/healthz"
  echo "  Прод-сертификат: PP_DOMAIN=<домен> bash nginx/get_prod_certs.sh"
  exit 0
fi
echo "СЕРВИСЫ НЕ ЗДОРОВЫ за 300 c — docker compose ps && docker compose logs --tail 50"
exit 1
