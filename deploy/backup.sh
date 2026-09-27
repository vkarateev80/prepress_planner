#!/usr/bin/env bash
# Резервное копирование SaaS-стека (DEPLOY_CHECKLIST §9):
#   1) PostgreSQL → дамп gzip в <выход>/db_<метка>.sql.gz
#   2) MinIO      → зеркало bucket в <выход>/bucket/  (aws s3 sync)
#   3) Offsite    → вынос <выход>/ на внешнее S3-совместимое хранилище
#                   (опционально; HANDOFF §9 п.3)
#
# Запуск на сервере из каталога deploy/:
#   cd deploy && bash backup.sh [выходной_каталог]   # по умолчанию ./backups
#
# Offsite (шаг 3) включается переменными окружения (например, в .env или
# в строке cron); без PP_OFFSITE_S3_BUCKET шаг пропускается:
#   PP_OFFSITE_S3_BUCKET           — целевой bucket (обязателен для шага 3)
#   PP_OFFSITE_S3_ENDPOINT         — https://s3.example.com (пусто → AWS S3)
#   PP_OFFSITE_S3_REGION           — регион (по умолчанию us-east-1)
#   PP_OFFSITE_S3_PREFIX           — префикс ключа (по умолчанию prepress-backups)
#   PP_OFFSITE_ACCESS_KEY_ID       — ключ доступа (обязателен для шага 3)
#   PP_OFFSITE_SECRET_ACCESS_KEY   — секрет (обязателен для шага 3)
# Пример цели: Яндекс Object Storage, Wasabi, Backblaze B2 (S3-API), Ceph.
# Синхронизация инкрементальная (aws s3 sync) — старые метки не удаляются;
# чистку стороннего хранилища делайте его средствами (生命周期/ lifecycle).
#
# Крон (ежедневно в 04:00, лог в /var/log/pp-backup.log):
#   0 4 * * * cd /opt/stack/deploy && bash backup.sh >> /var/log/pp-backup.log 2>&1
#
# Требуется запущенный стек (postgresql, minio). Для объектного хранилища
# используется сервис minio-init (amazon/aws-cli) — minio/mc больше не
# публикуется (см. deploy/docker-compose.yml).
#
# Восстановление:
#   gunzip -c backups/db_*.sql.gz | docker compose exec -T postgresql \
#     psql -U pp_user -d prepress_saas
#   docker compose run --rm --no-deps --entrypoint /bin/sh \
#     -v "$PWD/backups/bucket:/work" -w /work \
#     minio-init -c 'aws --endpoint-url http://minio:9000 s3 sync /work s3://"$BUCKET"'
#   Offsite: скачать метку aws s3 cp --recursive s3://<bucket>/<prefix>/<метка>/ …
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

echo "=== 1/3 PostgreSQL: pg_dump (${DB_USER}/${DB_NAME}) ==="
docker compose exec -T postgresql \
  pg_dump -U "$DB_USER" -d "$DB_NAME" \
  | gzip > "$OUT/db_${STAMP}.sql.gz"
echo "  → $OUT/db_${STAMP}.sql.gz ($(wc -c < "$OUT/db_${STAMP}.sql.gz") байт)"

echo "=== 2/3 MinIO: aws s3 sync → $OUT/bucket ==="
# minio-init (compose) задаёт AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY/BUCKET/ENDPOINT.
# --entrypoint обязателен: entrypoint сервиса — свой health-скрипт, который
# игнорирует переданную команду (проверено живым прогоном 2026-09-27).
docker compose run --rm --no-deps --entrypoint /bin/sh \
  -v "$OUT/bucket:/work" -w /work \
  minio-init -c \
  'aws --endpoint-url "$ENDPOINT" s3 sync "s3://$BUCKET" /work'
echo "  → $OUT/bucket/"

echo "=== 3/3 Offsite: вынос копии на внешнее хранилище ==="
if [ -n "${PP_OFFSITE_S3_BUCKET:-}" ]; then
  : "${PP_OFFSITE_ACCESS_KEY_ID:?PP_OFFSITE_S3_BUCKET задан — требуется PP_OFFSITE_ACCESS_KEY_ID}"
  : "${PP_OFFSITE_SECRET_ACCESS_KEY:?PP_OFFSITE_S3_BUCKET задан — требуется PP_OFFSITE_SECRET_ACCESS_KEY}"
  OFFSITE_REGION="${PP_OFFSITE_S3_REGION:-us-east-1}"
  OFFSITE_PREFIX="${PP_OFFSITE_S3_PREFIX:-prepress-backups}"
  docker compose run --rm --no-deps --entrypoint /bin/sh \
    -v "$OUT:/work:ro" \
    -e AWS_ACCESS_KEY_ID="$PP_OFFSITE_ACCESS_KEY_ID" \
    -e AWS_SECRET_ACCESS_KEY="$PP_OFFSITE_SECRET_ACCESS_KEY" \
    -e AWS_DEFAULT_REGION="$OFFSITE_REGION" \
    -e OFFSITE_ENDPOINT="${PP_OFFSITE_S3_ENDPOINT:-}" \
    -e OFFSITE_BUCKET="$PP_OFFSITE_S3_BUCKET" \
    -e OFFSITE_PREFIX="$OFFSITE_PREFIX/$STAMP" \
    minio-init -c '
      if [ -n "$OFFSITE_ENDPOINT" ]; then set -- --endpoint-url "$OFFSITE_ENDPOINT"; else set -- ; fi
      aws "$@" s3 sync /work "s3://$OFFSITE_BUCKET/$OFFSITE_PREFIX/"
    '
  echo "  → s3://${PP_OFFSITE_S3_BUCKET}/${OFFSITE_PREFIX}/${STAMP}/"
else
  echo "  пропущено: PP_OFFSITE_S3_BUCKET не задан (offsite-копия выключена)"
fi

echo "Готово: резервные копии в $OUT (метка ${STAMP})."
