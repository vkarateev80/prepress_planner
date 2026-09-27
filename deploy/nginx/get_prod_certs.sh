#!/usr/bin/env bash
# Прод-TLS: запрос/обновление сертификата Let's Encrypt для реального домена
# (HANDOFF §9 п.1). Работает на сервере из каталога deploy/:
#
#   PP_DOMAIN=example.com PP_ACME_EMAIL=admin@example.com \
#     bash nginx/get_prod_certs.sh          # запрос (или обновление keep)
#   PP_DOMAIN=example.com bash nginx/get_prod_certs.sh renew
#
# Как это работает:
#   1) webroot-челлендж отдаёт edge-nginx (location /.well-known/acme-challenge/
#      в pp-web-tls.conf, каталог deploy/acme примонтирован в контейнер);
#   2) certbot идёт в docker (образ certbot/certbot), состояние — deploy/certbot/
#      (в .gitignore; приватные ключи не попадают в git);
#   3) готовые fullchain.pem/privkey.pem копируются в deploy/nginx/certs/
#      (та же папка, что у dev-сертификата gen_dev_certs.sh — прод затирает dev)
#      и nginx перезагружается.
#
# Обновление (renew) — тот же скрипт с флагом renew; cron раз в неделю:
#   0 3 * * 1 cd /opt/stack/deploy && PP_DOMAIN=example.com bash nginx/get_prod_certs.sh renew >> /var/log/pp-certbot.log 2>&1
#
# Требования: DNS A/AAAA-запись домена указывает на этот сервер, порты 80/443
# открыты (иначе Let's Encrypt не пройдёт HTTP-01). Проверка до certbot —
# шаг 3 скрипта.
set -euo pipefail

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # → deploy/

MODE="${1:-issue}"
case "$MODE" in
  issue|renew) ;;
  *) echo "Ошибка: неизвестный режим '$MODE' (ожидается issue|renew)" >&2; exit 2 ;;
esac

: "${PP_DOMAIN:?задайте PP_DOMAIN=домен (например, example.com)}"
ACME_EMAIL="${PP_ACME_EMAIL:-admin@${PP_DOMAIN}}"
ACME_DIR="$PWD/acme"
LE_DIR="$PWD/certbot"
CERTS_DIR="$PWD/nginx/certs"
CHALLENGE=".well-known/acme-challenge/pp-acme-selftest"

echo "=== 1/5 Подготовка webroot ==="
mkdir -p "$ACME_DIR/.well-known/acme-challenge" "$CERTS_DIR"

echo "=== 2/5 Edge-nginx (порт 80) ==="
if ! curl -sf --max-time 3 http://127.0.0.1/ >/dev/null 2>&1; then
  docker compose up -d web
  for _ in $(seq 1 30); do
    curl -sf --max-time 2 http://127.0.0.1/ >/dev/null 2>&1 && break
    sleep 1
  done
fi
curl -sf --max-time 3 http://127.0.0.1/ >/dev/null 2>&1 \
  || { echo "Ошибка: edge-nginx (порт 80) не отвечает" >&2; exit 1; }

echo "=== 3/5 Самопроверка ACME-челленджа ==="
echo "acme-ok-$(date +%s)" > "$ACME_DIR/$CHALLENGE"
LOCAL_BODY="$(curl -sf --max-time 3 "http://127.0.0.1/$CHALLENGE" || true)"
case "$LOCAL_BODY" in
  acme-ok-*) echo "  локально: OK" ;;
  *) echo "Ошибка: nginx не отдаёт $CHALLENGE (см. pp-web-tls.conf, mount acme)" >&2; exit 1 ;;
esac
PUB_BODY="$(curl -sf --max-time 8 "http://$PP_DOMAIN/$CHALLENGE" || true)"
case "$PUB_BODY" in
  acme-ok-*) echo "  через домен: OK" ;;
  *) echo "Ошибка: http://$PP_DOMAIN/ недоступен снаружи." >&2
     echo "  Проверьте DNS A/AAAA-запись и фаервол (порт 80) — Let's Encrypt не пройдёт HTTP-01." >&2
     exit 1 ;;
esac
rm -f "$ACME_DIR/$CHALLENGE"

if [ "$MODE" = "renew" ]; then
  echo "=== 4/5 certbot renew ==="
  docker run --rm \
    -v "$LE_DIR:/etc/letsencrypt" \
    -v "$ACME_DIR:/var/www/acme" \
    certbot/certbot renew --webroot -w /var/www/acme --non-interactive
else
  echo "=== 4/5 certbot certonly (${PP_DOMAIN}) ==="
  docker run --rm \
    -v "$LE_DIR:/etc/letsencrypt" \
    -v "$ACME_DIR:/var/www/acme" \
    certbot/certbot certonly --webroot -w /var/www/acme \
      -d "$PP_DOMAIN" \
      --email "$ACME_EMAIL" --agree-tos --non-interactive \
      --keep-until-expiring
fi

echo "=== 5/5 Установка сертификата + reload nginx ==="
SRC="$LE_DIR/live/$PP_DOMAIN"
[ -f "$SRC/fullchain.pem" ] && [ -f "$SRC/privkey.pem" ] \
  || { echo "Ошибка: сертификат не найден в $SRC (live/)" >&2; exit 1; }
cp "$SRC/fullchain.pem" "$CERTS_DIR/fullchain.pem"
cp "$SRC/privkey.pem" "$CERTS_DIR/privkey.pem"
docker compose exec web nginx -s reload
echo "Готово: $CERTS_DIR/{fullchain,privkey}.pem (домен $PP_DOMAIN), nginx перезагружен."
echo "Проверка: curl -vI https://$PP_DOMAIN/healthz"
