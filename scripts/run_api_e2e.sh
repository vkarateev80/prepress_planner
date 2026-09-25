#!/usr/bin/env bash
# Сквозная проверка расчётного пути «api → domain-worker → packages/core»
# (System Design §3.3 С5, §12.6; PRD §10.2 эталон 1:1).
#
# Поднимает реальный domain-worker (Dart VM, 8101) и прогоняет HTTP-путь:
#   POST /api/projects                      (создание проекта)
#   POST /api/projects/{id}/calculate       (полная доменная цепочка)
# и сверяет эталонные числа PRD §10.2 (delta = 0.0).
#
# Зависимости: dart (VM), python3 + fastapi (как в services/api).
# Моки не используются: вызывается живой воркер по HTTP.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DART="${ROOT}/.tools/dart-sdk/bin/dart"
[ -x "$DART" ] || DART="dart"

WORKER_DIR="${ROOT}/services/domain-worker"
API_DIR="${ROOT}/services/api"
PORT="${PP_E2E_WORKER_PORT:-8199}"

command -v "$DART" >/dev/null 2>&1 || { echo "FAIL: dart не найден"; exit 1; }

echo "=== 1. Запуск domain-worker :${PORT} ==="
cd "$WORKER_DIR"
"$DART" pub get --offline >/dev/null 2>&1 || true
"$DART" bin/domain_worker.dart --port "$PORT" > /tmp/pp_e2e_worker.log 2>&1 &
WORKER_PID=$!
cleanup() { kill "$WORKER_PID" >/dev/null 2>&1 || true; }
trap cleanup EXIT

for i in $(seq 1 40); do
  if python3 - "$PORT" <<'PY' 2>/dev/null
import sys, urllib.request
urllib.request.urlopen(f"http://127.0.0.1:{sys.argv[1]}/healthz", timeout=1).read()
PY
  then break; fi
  sleep 0.5
  if [ "$i" -eq 40 ]; then
    echo "FAIL: domain-worker не поднялся (см. /tmp/pp_e2e_worker.log)"; exit 1
  fi
done
echo "worker готов: $(python3 -c "
import sys,json,urllib.request
print(json.load(urllib.request.urlopen('http://127.0.0.1:${PORT}/healthz'))['service'])")"

echo "=== 2. Живой путь api → domain-worker (эталон PRD §10.2) ==="
cd "$API_DIR"
PP_E2E_WORKER_PORT="$PORT" python3 - "$ROOT" <<'PY'
import base64, os, sys, tempfile
from pathlib import Path

ROOT = Path(sys.argv[1])
sys.path.insert(0, str(ROOT / "services" / "api"))

import pytest  # noqa: F401  (наличие окружения services/api)
from fastapi.testclient import TestClient

from api_app import main as api_main
from api_app import repo as repo_mod
from api_app.auth import Membership, Principal
from api_app.config import Config
from api_app.storage import MemoryObjectStorage

PORT = os.environ["PP_E2E_WORKER_PORT"]
TOKEN = "e2e-token"
ORG = "orgE2E0000000001"

tmp = tempfile.mkdtemp(prefix="pp_e2e_api_")
root = ROOT / "services" / "api"
os.environ["DB_URL"] = "sqlite:///" + str(Path(tmp) / "e2e.db")

cfg = Config({
    "PP_DATA_DIR": tmp,
    "PP_AUTH_URL": "http://auth.test:8121",
    "DOMAIN_WORKER_URL": f"http://127.0.0.1:{PORT}",
    "PP_STORAGE_BACKEND": "memory",
    "PP_AUTH_REQUIRED": "1",
    "PP_ENTITLEMENT_ENFORCE": "0",
    "OBJECT_STORAGE_ENDPOINT": "http://minio.test:9000",
})

class Verifier:
    def verify(self, token):
        if token != TOKEN:
            from api_app.auth import AuthError
            raise AuthError(401, "Сессия недействительна.", "invalid_token")
        return Principal(user_id="u-e2e", email="e2e@example.com",
                         orgs=[Membership(ORG, "owner")])

cfg.verifier = Verifier()
runtime = api_main.build_runtime(cfg)
runtime["storage"] = MemoryObjectStorage()
runtime["repo"] = repo_mod.Repo(runtime["db"], runtime["storage"],
                                key_prefix="org", max_versions=3)
runtime["storage_status"] = "memory"
api_main.STATE.update(runtime)

client = TestClient(api_main.app)
h = {"Authorization": f"Bearer {TOKEN}"}

r = client.post("/api/projects", json={"name": "E2E эталон"}, headers=h)
assert r.status_code == 201, r.text
pid = r.json()["project_id"]

params = {"label_w": 50, "label_h": 30, "gap_x": 3, "gap_y": 3,
          "z_teeth": 96, "cp": 3.175, "cyl_width": 300, "web_width": 300,
          "mode": "count", "count": 5000}
teo_input = {"material_id": "paper-sa-80", "machine_id": "flexo-300"}

r = client.post(f"/api/projects/{pid}/calculate",
                json={"layout_params": params, "teo_input": teo_input}, headers=h)
assert r.status_code == 200, r.text
body = r.json()
state = body["state"]
calc = state["calc"]
teo = body["result"]["teo"]

EXPECTED = [
    ("rows", calc["rows"], 9),
    ("cols", calc["cols"], 5),
    ("labelCount", calc["count"], 5040),
    ("revolutions", calc["revs"], 112),
    ("totalLength", calc["length"], 34137.6),
    ("wastePercent", calc["wastePct"], 26.18),
    ("perLabelArea", calc["perLabelArea"], 2032.0),
    ("rapport", calc["rapport"], 304.8),
    ("costPer1000", teo["costPer1000"], 704.88),
    ("totalCost", teo["totalCost"], 3552.58),
    ("machineCost", teo["machineCost"], 2528.45),
    ("materialCost", teo["materialCost"], 1024.13),
    ("runTimeHours", teo["runTimeHours"], 0.0057),
]

print(f"{'поле':<16}{'ожидание':>12}{'факт':>14}{'delta':>10}  статус")
failed = []
for name, got, want in EXPECTED:
    delta = abs(float(got) - float(want))
    ok = delta <= 1e-9
    if not ok:
        failed.append(name)
    print(f"{name:<16}{want:>12}{got:>14}{delta:>10.1e}  {'PASS' if ok else 'FAIL'}")

variants = state.get("variants") or []
print(f"\nвариантов раскроя: {len(variants)} (лучший: "
      f"{variants[0]['rows']}×{variants[0]['cols']}, "
      f"{variants[0]['wastePct']}% отходов)" if variants else "вариантов нет")

ref = body.get("reference") or {}
print(f"сверка воркера: checked={ref.get('checked')} passed={ref.get('passed')} "
      f"delta={ref.get('delta')}")
metrics = body.get("metrics") or {}
print(f"время расчёта: {metrics.get('totalMs')} мс, стадии: {metrics.get('executedStages')}")

assert ref.get("passed") is True, "воркер не подтвердил эталон"
assert not failed, f"эталон не сошёлся: {failed}"
print("\nE2E OK: api → domain-worker → packages/core, эталон PRD §10.2 сошёлся 1:1")
PY

echo "=== 3. Проверка через скалярный /calc ==="
cd "$API_DIR"
PP_E2E_WORKER_PORT="$PORT" python3 - "$ROOT" <<'PY'
import os, sys, tempfile
from pathlib import Path
ROOT = Path(sys.argv[1])
sys.path.insert(0, str(ROOT / "services" / "api"))
from fastapi.testclient import TestClient
from api_app import main as api_main
from api_app import repo as repo_mod
from api_app.auth import Membership, Principal
from api_app.config import Config
from api_app.storage import MemoryObjectStorage

PORT = os.environ["PP_E2E_WORKER_PORT"]
TOKEN, ORG = "e2e-token", "orgE2E0000000001"
tmp = tempfile.mkdtemp(prefix="pp_e2e_api2_")

cfg = Config({
    "PP_DATA_DIR": tmp, "PP_AUTH_URL": "http://auth.test:8121",
    "DOMAIN_WORKER_URL": f"http://127.0.0.1:{PORT}",
    "PP_STORAGE_BACKEND": "memory", "PP_AUTH_REQUIRED": "1",
    "PP_ENTITLEMENT_ENFORCE": "0",
})
cfg.verifier = type("V", (), {"verify": lambda self, t: Principal(
    user_id="u", orgs=[Membership(ORG, "owner")])})()
rt = api_main.build_runtime(cfg)
rt["storage"] = MemoryObjectStorage()
rt["repo"] = repo_mod.Repo(rt["db"], rt["storage"], key_prefix="org", max_versions=3)
api_main.STATE.update(rt)
client = TestClient(api_main.app)
h = {"Authorization": f"Bearer {TOKEN}"}
pid = client.post("/api/projects", json={"name": "E2E"}, headers=h).json()["project_id"]
params = {"label_w": 50, "label_h": 30, "gap_x": 3, "gap_y": 3, "z_teeth": 96,
          "cp": 3.175, "cyl_width": 300, "web_width": 300, "mode": "count",
          "count": 5000}
for path, key, want in (("calc", "calc", 5040), ("variants", "variants", None),
                        ("teo", "teo", 704.88)):
    payload = {"layout_params": params}
    if path == "teo":
        payload["teo_input"] = {"material_id": "paper-sa-80", "machine_id": "flexo-300"}
    r = client.post(f"/api/projects/{pid}/{path}", json=payload, headers=h)
    assert r.status_code == 200, (path, r.text)
    body = r.json()
    if path == "variants":
        assert body["total"] >= 1, body
        got = f"{body['total']} вариантов, лучший {body['variants'][0]['rows']}×{body['variants'][0]['cols']}"
    elif path == "calc":
        got = body["calc"]["count"]
        assert got == want, (got, want)
    else:
        got = body["teo"]["costPer1000"]
        assert got == want, (got, want)
    print(f"POST /api/projects/{{id}}/{path:<9} → 200: {got}")

print("\nE2E OK: скалярные эндпоинты §12.6 отвечают эталоном через живой воркер")
PY

echo
echo "ALL PASS (e2e: api → domain-worker → packages/core)"
