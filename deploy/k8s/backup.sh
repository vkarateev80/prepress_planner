#!/usr/bin/env bash
# Резервное копирование стека «Препресс-Планер» в k3s (deploy/k8s).
# Замена compose-варианта (deploy/backup.sh) — тот рассчитан на docker compose.
#
#   1) PostgreSQL → <выход>/db_<метка>.sql.gz   (kubectl exec pg_dump)
#   2) MinIO      → <выход>/bucket/             (tar-поток из контейнера)
#   3) Offsite    → вынос на внешний S3         (опционально, PP_OFFSITE_*)
#
# Запуск (на сервере):
#   bash /opt/pp/stack/deploy/k8s/backup.sh [выходной_каталог]
#   по умолчанию выход: <каталог скрипта>/../backups
#
# Крон (см. k8s/README.md): 0 4 * * * …
# Восстановление БД:
#   gunzip -c db_<метка>.sql.gz | kubectl -n prepress exec -i deploy/postgresql -- \
#     psql -U pp_user -d prepress_saas
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NS=prepress
OUT="${1:-$DIR/../backups}"
case "$OUT" in /*) ;; *) OUT="$PWD/$OUT" ;; esac
STAMP="$(date +%Y%m%d_%H%M%S)"
mkdir -p "$OUT/bucket"

echo "=== 1/3 PostgreSQL: pg_dump (${STAMP}) ==="
kubectl -n "$NS" exec deploy/postgresql -- \
  pg_dump -U pp_user -d prepress_saas \
  | gzip > "$OUT/db_${STAMP}.sql.gz"
echo "  → $OUT/db_${STAMP}.sql.gz ($(wc -c < "$OUT/db_${STAMP}.sql.gz") байт)"

echo "=== 2/3 MinIO: зеркало данных ==="
kubectl -n "$NS" exec deploy/minio -- tar cf - -C /data . \
  | tar xf - -C "$OUT/bucket"
echo "  → $OUT/bucket/ ($(find "$OUT/bucket" -type f | wc -l | tr -d ' ') файлов)"

echo "=== 3/3 Offsite (опционально) ==="
if [ -n "${PP_OFFSITE_S3_BUCKET:-}" ]; then
  : "${PP_OFFSITE_ACCESS_KEY_ID:?PP_OFFSITE_S3_BUCKET задан — нужен PP_OFFSITE_ACCESS_KEY_ID}"
  : "${PP_OFFSITE_SECRET_ACCESS_KEY:?PP_OFFSITE_S3_BUCKET задан — нужен PP_OFFSITE_SECRET_ACCESS_KEY}"
  docker run --rm \
    -e AWS_ACCESS_KEY_ID="$PP_OFFSITE_ACCESS_KEY_ID" \
    -e AWS_SECRET_ACCESS_KEY="$PP_OFFSITE_SECRET_ACCESS_KEY" \
    -e AWS_DEFAULT_REGION="${PP_OFFSITE_S3_REGION:-us-east-1}" \
    -e AWS_ENDPOINT_URL="${PP_OFFSITE_S3_ENDPOINT:-}" \
    -v "$OUT:/work:ro" \
    amazon/aws-cli:2.17.49 \
    s3 sync /work "s3://${PP_OFFSITE_S3_BUCKET}/${PP_OFFSITE_S3_PREFIX:-prepress-backups}/${STAMP}/"
  echo "  → s3://${PP_OFFSITE_S3_BUCKET}/${PP_OFFSITE_S3_PREFIX:-prepress-backups}/${STAMP}/"
else
  echo "  пропущено: PP_OFFSITE_S3_BUCKET не задан"
fi

echo "Готово: $OUT (метка ${STAMP})."
