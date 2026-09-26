#!/usr/bin/env bash
# Dev TLS-сертификат для deploy/nginx/pp-web-tls.conf (стенд/локальная
# проверка `nginx -t`). Прод — Let's Encrypt/certbot (deploy/README.md).
#
# Выход: deploy/nginx/certs/{fullchain.pem, privkey.pem} — каталог в
# .gitignore, ключи в git не попадают.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="$DIR/certs"
CN="${PP_TLS_CN:-localhost}"

mkdir -p "$OUT"
if [ -f "$OUT/fullchain.pem" ] && [ -f "$OUT/privkey.pem" ]; then
  echo "Уже есть: $OUT/fullchain.pem + privkey.pem — не перезаписываю."
  echo "(Для регенерации удалите их и запустите скрипт снова.)"
  exit 0
fi

openssl req -x509 -newkey rsa:2048 -nodes -days 365 \
  -keyout "$OUT/privkey.pem" -out "$OUT/fullchain.pem" \
  -subj "/CN=$CN" \
  -addext "subjectAltName=DNS:$CN,DNS:prepressplan.ru,IP:127.0.0.1" \
  2>/dev/null

echo "Dev-сертификат создан (365 дней, CN=$CN):"
echo "  $OUT/fullchain.pem"
echo "  $OUT/privkey.pem"
echo "Браузер будет ругаться — это нормально для стенда; в прод ставьте certbot."
