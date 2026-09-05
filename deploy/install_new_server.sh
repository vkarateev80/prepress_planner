#!/bin/bash
# =============================================================
#  Первичная настройка НОВОГО Ubuntu-сервера «Препресс-Планер»
#  Запуск от root:  bash install_new_server.sh
#
#  Предполагается структура (из бандла pp-new-server-stack.tar.gz):
#    <root>/deploy/{docker-compose.yml, nginx/, .env.example, install_new_server.sh}
#    <root>/deploy/web/          - статика flutter build web
#    <root>/services/{converter,auth,payments}/
#
#  Скрипт идемпотентен: повторный запуск просто пересобирает/перезапускает.
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

echo "[3/5] .env (секрет)"
if [ ! -f .env ]; then
  SECRET="${PP_AUTH_SECRET:-$(openssl rand -hex 32)}"
  cat > .env <<EOF
# Сгенерирован install_new_server.sh
PP_AUTH_SECRET=${SECRET}

PP_SMTP_HOST=
PP_SMTP_PORT=587
PP_SMTP_USER=
PP_SMTP_PASSWORD=
PP_SMTP_FROM=
EOF
  echo ".env создан (PP_AUTH_SECRET сгенерирован). Почту при необходимости заполните вручную."
else
  echo ".env уже есть — оставляю."
fi

echo "[4/5] docker compose up -d --build"
docker compose up -d --build

echo "[5/5] ожидание здоровья"
for i in $(seq 1 30); do
  C8120=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:8120/healthz || true)
  C8121=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:8121/healthz || true)
  C8122=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:8122/healthz || true)
  C8081=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:8081/ || true)
  echo "  probe: converter=$C8120 auth=$C8121 payments=$C8122 web=$C8081"
  if [ "$C8120" = "200" ] && [ "$C8121" = "200" ] && [ "$C8122" = "200" ] && [ "$C8081" = "200" ]; then
    echo "ВСЕ СЕРВИСЫ РАБОТАЮТ."
    docker compose ps
    echo
    echo "Web:      http://<IP-сервера>:8081"
    echo "Прямые:   converter 8120, auth 8121, payments 8122"
    exit 0
  fi
  sleep 5
done
echo "НЕ ВСЕ СЕРВИСЫ ПОДНЯЛИСЬ за 150 c — смотрите: docker compose ps && docker compose logs"
exit 1
