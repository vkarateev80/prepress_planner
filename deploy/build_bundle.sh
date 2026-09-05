#!/bin/bash
# =============================================================
#  Сборка единого бандла для НОВОГО сервера (Linux/macOS).
#  Использование: bash build_bundle.sh [путь к flutter web-сборке]
#  По умолчанию web-сборка: ../../app/build/web  (относительно deploy/)
#
#  Результат: ../../pp-new-server-stack.tar.gz
#  Перенос:    scp pp-new-server-stack.tar.gz root@<новый-IP>:/
#  Развёртывание на сервере:
#    tar xzf pp-new-server-stack.tar.gz && cd stack/deploy && bash install_new_server.sh
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

echo "Копирую deploy/, services/, web/ …"
mkdir -p "$STAGE/stack/deploy" "$STAGE/stack/services"
cp -r deploy/. "$STAGE/stack/deploy/"
cp -r "$WEB" "$STAGE/stack/deploy/web"
cp -r "$ROOT/services/converter" "$ROOT/services/auth" "$ROOT/services/payments" "$STAGE/stack/services/"

echo "Чищу кеши/артефакты сервисов …"
find "$STAGE" -type d \( -name __pycache__ -o -name .pytest_cache -o -name data -o -name .dsh-tmp \) -prune -exec rm -rf {} +
find "$STAGE" -type f \( -name '*.pyc' -o -name '*.db' \) -delete

cd "$STAGE"
tar czf "$ROOT/pp-new-server-stack.tar.gz" stack
echo "Готово: $ROOT/pp-new-server-stack.tar.gz ($(du -h "$ROOT/pp-new-server-stack.tar.gz" | cut -f1))"
