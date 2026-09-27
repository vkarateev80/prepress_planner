#!/bin/bash
# =============================================================
#  Сборка единого бандла для нового сервера (Linux/macOS).
#  Использование: bash build_bundle.sh [путь к flutter web-сборке]
#  По умолчанию web-сборка: ../../app/build/web  (относительно deploy/)
#
#  Результат: ../../pp-new-server-stack.tar.gz
#  Перенос:    scp pp-new-server-stack.tar.gz root@<IP>:/tmp/
#  Развёртывание: tar xzf … && cd stack/deploy && bash install_new_server.sh
#
#  Состав (текущий SaaS-стек): deploy/ (+ web/), services/{api,converter,
#  auth,payments,domain-worker}, packages/core, Dockerfile.domain-worker.
#  Секреты/артефакты (.env, *.db, data/, backups/, acme/, certbot/) —
#  в бандл НЕ попадают.
# =============================================================
set -e
cd "$(dirname "$0")"
ROOT="$(cd .. && pwd)"
WEB="${1:-$ROOT/app/build/web}"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

if [ ! -f "$WEB/index.html" ]; then
  echo "Не найдена web-сборка: $WEB (сначала: flutter build web)"
  exit 1
fi

echo "Копирую deploy/, services/, packages/, web/ …"
mkdir -p "$STAGE/stack/deploy"
cp -r . "$STAGE/stack/deploy/"
mkdir -p "$STAGE/stack/deploy/web"
cp -r "$WEB/." "$STAGE/stack/deploy/web/"
mkdir -p "$STAGE/stack/services"
cp -r "$ROOT/services/api" "$ROOT/services/converter" "$ROOT/services/auth" \
      "$ROOT/services/payments" "$ROOT/services/domain-worker" \
      "$STAGE/stack/services/"
cp -r "$ROOT/packages/core" "$STAGE/stack/packages/core" 2>/dev/null || {
  mkdir -p "$STAGE/stack/packages"; cp -r "$ROOT/packages/core" "$STAGE/stack/packages/core"; }
cp "$ROOT/Dockerfile.domain-worker" "$STAGE/stack/"

echo "Чищу секреты и артефакты …"
rm -f "$STAGE/stack/deploy/.env"
rm -rf "$STAGE/stack/deploy/backups" "$STAGE/stack/deploy/acme" \
       "$STAGE/stack/deploy/certbot" "$STAGE/stack/deploy/nginx/certs"
find "$STAGE" -type d \( -name __pycache__ -o -name .pytest_cache -o -name data \
       -o -name .dsh-tmp -o -name .dart_tool \) -prune -exec rm -rf {} + 2>/dev/null || true
find "$STAGE" -type f \( -name '*.pyc' -o -name '*.db' \) -delete

cd "$STAGE"
tar czf "$ROOT/pp-new-server-stack.tar.gz" stack
echo "Готово: $ROOT/pp-new-server-stack.tar.gz ($(du -h "$ROOT/pp-new-server-stack.tar.gz" | cut -f1))"
echo "Проверка содержимого:"
tar tzf "$ROOT/pp-new-server-stack.tar.gz" | grep -E "docker-compose.yml|Dockerfile.domain-worker|deploy/web/index.html|services/api/api_app/main.py|packages/core/pubspec.yaml" | head
