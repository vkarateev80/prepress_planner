#!/usr/bin/env bash
# Развёртывание «Препресс-Планер» в k3s (deploy/k8s).
# Запуск на сервере ИЗ каталога deploy/ (структура /opt/pp/stack/deploy):
#   cd deploy && bash k8s/apply.sh
#
# Что делает:
#   1) namespace + секреты (генерируются при первом запуске, идемпотентно);
#   2) импорт образов pp-* из dockerd в containerd k3s;
#   3) сборка pp-web (статика SPA + прокси) и её импорт;
#   4) kubectl apply всех манифестов;
#   5) ожидание готовности.
#
# DNS (A prepressplan.ru → IP сервера) должен быть указан ДО выпуска TLS
# (Ingress сам запросит сертификат после появления записи).
set -euo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # → deploy/

echo "[1/5] namespace + секреты"
kubectl apply -f k8s/00-namespace.yaml
if ! kubectl -n prepress get secret pp-secrets >/dev/null 2>&1; then
  kubectl -n prepress create secret generic pp-secrets \
    --from-literal=PP_AUTH_SECRET="$(openssl rand -hex 32)" \
    --from-literal=PP_DB_PASSWORD="$(openssl rand -hex 24)" \
    --from-literal=MINIO_ACCESS_KEY="pp$(openssl rand -hex 12)" \
    --from-literal=MINIO_SECRET_KEY="$(openssl rand -hex 24)" \
    --dry-run=client -o yaml | kubectl apply -f -
  echo "  секрет pp-secrets сгенерирован"
else
  echo "  pp-secrets уже есть — оставляю"
fi
kubectl apply -f k8s/01-config.yaml

echo "[2/5] импорт образов pp-* из docker в containerd k3s"
docker save pp-api:latest pp-auth:latest pp-billing:latest \
  pp-converter:latest pp-domain-worker:latest \
  | k3s ctr images import -

echo "[3/5] сборка и импорт pp-web (SPA + nginx-прокси)"
docker build -q -f k8s/Dockerfile.web -t pp-web:latest .
docker save pp-web:latest | k3s ctr images import -

echo "[4/5] применение манифестов"
kubectl apply -f k8s/10-postgres.yaml
kubectl apply -f k8s/11-minio.yaml
kubectl apply -f k8s/20-auth.yaml
kubectl apply -f k8s/21-billing.yaml
kubectl apply -f k8s/24-domain-worker.yaml
kubectl apply -f k8s/23-converter.yaml
kubectl apply -f k8s/22-api.yaml
kubectl apply -f k8s/30-web.yaml
kubectl apply -f k8s/40-ingress.yaml

echo "[5/5] ожидание готовности"
for d in postgresql minio auth billing domain-worker converter api web; do
  kubectl -n prepress rollout status "deploy/$d" --timeout=300s
done

echo
echo "ГОТОВО. Проверка:"
echo "  kubectl -n prepress get pods"
echo "  curl -sk --resolve prepressplan.ru:443:<IP> https://prepressplan.ru/healthz"
echo "TLS выпустится автоматически после указания DNS A prepressplan.ru → <IP>:"
echo "  kubectl -n prepress describe certificate prepressplan-tls"
