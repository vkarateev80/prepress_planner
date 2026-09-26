#!/usr/bin/env bash
# Резервное копирование SaaS-стека (DEPLOY_CHECKLIST §9):
#   1) PostgreSQL → дамп gzip в <выход>/db_<метка>.sql.gz
#   2) MinIO      → зеркало bucket в <выход>/bucket/  (aws s3 sync)
#
# Запуск на сервере из каталога deploy/:
#   cd deploy && bash backup.sh [выходной_каталог]   # по умолчанию ./backups
#
# Требуется запущенный стек (postgresql, minio). Для объектного хранилища
# используется сервис minio-init (amazon/aws-cli) — minio/mc больше не
# публикуется (см. deploy/docker-compose.yml).
#
# Восстановление:
#   gunzip -c backups/db_*.sql.gz | docker compose exec -T postgresql \
#     psql -U pp_user -d prepress_saas
#   docker compose run --rm --no-deps -v "$PWD/backups/bucket:/work" -w /work \
#     minio-init /bin/sh -c 'aws --endpoint-url http://minio:9000 s3 sync /work/bucket s3://"$BUCKET"'
set -euo pipefail

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

OUT="${1:-./backups}"
case "$OUT" in
  /*) ;;
  *) OUT="$PWD/$OUT" ;;
esac
STAMP="$(date +%Y%m%d_%H%M%S)"
mkdir -p "$OUT/bucket"

DB_USER="${PP_DB_USER:-pp_user}"
DB_NAME="${PP_DB_NAME:-prepress_saas}"

echo "=== 1/2 PostgreSQL: pg_dump (${DB_USER}/${DB_NAME}) ==="
docker compose exec -T postgresql \
  pg_dump -U "$DB_USER" -d "$DB_NAME" \
  | gzip > "$OUT/db_${STAMP}.sql.gz"
echo "  → $OUT/db_${STAMP}.sql.gz ($(wc -c < "$OUT/db_${STAMP}.sql.gz") байт)"

echo "=== 2/2 MinIO: aws s3 sync → $OUT/bucket ==="
# minio-init (compose) задаёт AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY/BUCKET/ENDPOINT.
docker compose run --rm --no-deps \
  -v "$OUT/bucket:/work" -w /work \
  minio-init /bin/sh -c \
  'aws --endpoint-url "$ENDPOINT" s3 sync "s3://$BUCKET" /work/bucket'
echo "  → $OUT/bucket/"

echo "Готово: резервные копии в $OUT (метка ${STAMP})."
