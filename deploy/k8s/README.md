# Развёртывание в k3s (185.227.144.229)

Весь стек «Препресс-Планер» работает в Kubernetes (k3s): Traefik — edge
(80/443, ACME), cert-manager — сертификаты Let's Encrypt, local-path — тома.
Docker-compose стек больше не используется (см. «Откат» ниже).

## Состав

| Ресурс | Образ | Что |
|---|---|---|
| `postgresql` | postgres:16-alpine | метаданные (ADR-5), PVC 10Gi |
| `minio` | alpine/minio (пин) | объекты, PVC 20Gi |
| `auth` | pp-auth | регистрации/сессии/организации/F-19, SQLite на PVC |
| `billing` | pp-billing | подписки/ЮKassa (ADR-3), PostgreSQL |
| `api` | pp-api | проекты/файлы/отчёты, PostgreSQL + MinIO |
| `converter` | pp-converter | AI/CDR/EPS → SVG/PDF (ADR-7), PVC 5Gi |
| `domain-worker` | pp-domain-worker | Dart AOT (ADR-2) |
| `web` | pp-web | SPA + nginx-прокси (`nginx-k8s.conf`), → Ingress |

Секреты — `kubectl -n prepress get secret pp-secrets` (генерирует `apply.sh`).
Несекретное — ConfigMap `pp-config` (`01-config.yaml`).

## Порядок развёртывания

```bash
# 1. На сервере (структура /opt/pp/stack/deploy):
cd /opt/pp/stack/deploy
#    (манифесты deploy/k8s из репозитория должны быть на месте)
bash k8s/apply.sh
```

```bash
# 2. DNS (до TLS!): A-запись prepressplan.ru → 185.227.144.229
#    (NS зоны — ns1/ns2.hosting.reg.ru; менять только A/AAAA @)
```

```bash
# 3. TLS выпускается автоматически (ClusterIssuer letsencrypt-prod):
kubectl -n prepress describe certificate prepressplan-tls
kubectl -n prepress get certificate,certificaterequest,order,challenge
```

## Проверка

```bash
kubectl -n prepress get pods
curl -s https://prepressplan.ru/healthz            # {"status":"ok",...}
curl -s https://prepressplan.ru/legal/ | head      # реквизиты/оферта
curl -s -o /dev/null -w '%{http_code}\n' https://prepressplan.ru/auth/devices  # 401
```

## Обновление образов

```bash
# на машине разработки: bash deploy/build_bundle.sh  → scp → на сервере:
docker save pp-api:latest … | k3s ctr images import -
kubectl -n prepress rollout restart deploy/api
```

Статика SPA: `docker build -f k8s/Dockerfile.web -t pp-web:latest .` (из
каталога `deploy/`, в `deploy/web/` должна лежать свежая `flutter build web`)
→ импорт → `rollout restart deploy/web`.

## Откат (если вернуться на docker-compose)

```bash
kubectl delete namespace prepress
cd deploy && docker compose up -d --build   # данные старого compose
#   лежат в прежних томах (не удалены)
```

## Ловушки k3s на этом сервере

- **80/443 заняты kube-proxy/nft (ServiceLB Traefik)** — docker-compose edge
  их не получит: ВЕСЬ трафик портов перехватывается в pod Traefik (даже из
  docker-proxy). Отсюда переход стека в k8s.
- `svclb-traefik` — штатный ServiceLB k3s; не удалять (это и есть edge).
- Образы `pp-*` собираются docker'ом и импортируются в containerd
  (`k3s ctr images import`) — k3s своих сборок не делает.
