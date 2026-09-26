# -*- coding: utf-8 -*-
"""Тесты доменных расчётов сервиса `api` через `domain-worker` (§12.6, ADR-2).

Проверяется сквозной путь «импорт → … → ТЭО» на уровне control plane:
  * `api` **не считает домен сам** — он вызывает `domain-worker`
    сервер-к-серверу (`POST /calculate`), проверяя членство/роль (§3.4);
  * перевод контракта §12.6 (snake_case `layout_params`/`teo_input`) в
    wire-схему воркера (camelCase `project_state.json v2`);
  * ответы `POST /projects/{id}/calc|variants|teo|teo/compare|pipeline`, а
    `/calculate` — синоним `/pipeline`;
  * эталонные числа PRD §10.2 доходят до клиента без изменений;
  * изоляция тенантов (N-4): чужой проект недоступен даже при знании id;
  * байты макета (`file_version_id`) передаются воркеру как base64 (F-1).

Внешние сервисы не вызываются: `auth` и `domain-worker` подменены фейками
(конвенция `services/api/tests/test_api_projects.py`). Сюита пригодна и для
PostgreSQL: PP_TEST_DB_URL.
"""
import base64

import os
import sys
import tempfile
from pathlib import Path
from typing import Any, Dict, List, Optional

import pytest

os.environ.pop("DB_URL", None)
if os.environ.get("PP_TEST_DB_URL"):
    os.environ["DB_URL"] = os.environ["PP_TEST_DB_URL"]

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from fastapi.testclient import TestClient  # noqa: E402

from api_app import main as api_main  # noqa: E402
from api_app import repo as repo_mod  # noqa: E402
from api_app.auth import AuthError, Membership, Principal  # noqa: E402
from api_app.config import Config  # noqa: E402
from api_app.domain import (DomainClient, DomainError,  # noqa: E402
                            normalize_layout_params, normalize_teo_input)
from api_app.storage import MemoryObjectStorage  # noqa: E402

TENANT_A = "orgA0000000000001"
TENANT_B = "orgB0000000000002"
TOKEN_A = "token-tenant-a"
TOKEN_B = "token-tenant-b"

FIXTURES = Path(__file__).resolve().parents[3] / "fixtures"

# --- эталон PRD §10.2 / System Design §1 -----------------------------------

REF_CALC: Dict[str, Any] = {
    "error": None,
    "labelW": 50.0,
    "labelH": 30.0,
    "gapX": 3.0,
    "gapYRequested": 3.0,
    "gapYActual": 3.8667,
    "rotated": False,
    "rows": 9,
    "cols": 5,
    "stepX": 53.0,
    "stepY": 33.8667,
    "usedWidth": 262.0,
    "webMin": 262.0,
    "perRev": 45,
    "revs": 112,
    "count": 5040,
    "countRequested": 5000,
    "excessLabels": 40,
    "rapport": 304.8,
    "dPitch": 97.0209,
    "dCyl": 96.0609,
    "length": 34137.6,
    "webWidth": 300.0,
    "areaMm2": 10241280.0,
    "areaM2": 10.2413,
    "usedAreaMm2": 7560000.0,
    "wastePct": 26.18,
    "perLabelArea": 2032.0,
    "mode": "count",
}

REF_TEO: Dict[str, Any] = {
    "error": None,
    "runTimeHours": 0.0057,
    "setupTimeHours": 0.5,
    "totalTimeHours": 0.5057,
    "shiftsUsed": 1,
    "shiftCost": 0.0,
    "machineCost": 2528.45,
    "materialCost": 1024.13,
    "toolingCost": 0.0,
    "markupCost": 0.0,
    "totalCost": 3552.58,
    "costPer1000": 704.88,
    "costPerLabel": 0.7,
    "fitsShift": True,
}

REF_CONSUMPTION = {
    "areaMm2": 10241280.0,
    "areaM2": 10.2413,
    "usedAreaMm2": 7560000.0,
    "wasteMm2": 2681280.0,
    "wastePct": 26.181102362204722,
    "perLabelMm2": 2032.0,
    "webMin": 262.0,
}

REFERENCE = {
    "checked": True,
    "passed": True,
    "expected": {"wastePct": 26.18, "perLabelArea": 2032.0, "lengthMm": 34137.6,
                 "rapportMm": 304.8, "costPer1000": 704.88, "totalCost": 3552.58,
                 "machineCost": 2528.45, "materialCost": 1024.13},
    "actual": {"wastePct": 26.18, "perLabelArea": 2032.0, "lengthMm": 34137.6,
               "rapportMm": 304.8, "costPer1000": 704.88, "totalCost": 3552.58,
               "machineCost": 2528.45, "materialCost": 1024.13},
    "delta": {"wastePct": 0.0, "perLabelArea": 0.0, "lengthMm": 0.0,
              "rapportMm": 0.0, "costPer1000": 0.0, "totalCost": 0.0,
              "machineCost": 0.0, "materialCost": 0.0},
    "eps": 0.005,
}

REF_STATE: Dict[str, Any] = {
    "schemaVersion": 2,
    "name": "Тираж 5000, 50×30",
    "inputFile": "",
    "params": {"labelW": 50.0, "labelH": 30.0, "gapX": 3.0, "gapY": 3.0,
               "zTeeth": 96, "cp": 3.175, "rapportManual": 0.0, "cylWidth": 300.0,
               "webWidth": 300.0, "undercut": 0.48, "minGap": 3.0,
               "mode": "count", "count": 5000, "length": 10000.0},
    "rawPaths": [],
    "healedPaths": [],
    "issues": [],
    "pattern": None,
    "arrayPaths": [],
    "calc": REF_CALC,
    "variants": [REF_CALC, {**REF_CALC, "rotated": True, "labelW": 30.0,
                            "labelH": 50.0, "rows": 5, "cols": 9}],
    "selectedVariantIndex": 0,
}

# --- фейковые внешние сервисы ---------------------------------------------

class FakeVerifier:
    """Замена `auth POST /auth/verify`."""

    def __init__(self, tokens: Dict[str, Principal]) -> None:
        self.tokens = tokens

    def verify(self, token: str) -> Principal:
        principal = self.tokens.get(token)
        if principal is None:
            raise AuthError(401, "Сессия недействительна или истекла — войдите заново.",
                            "invalid_token")
        return principal


class FakeDomain(DomainClient):
    """Замена `domain-worker` (8101): эталонные числа PRD §10.2.

    Наследует реальный `build_payload` (проверяется перевод контракта §12.6) и
    переопределяет только сетевой вызов `calculate`.
    """

    def __init__(self) -> None:
        super().__init__("http://domain-worker.test:8101")
        self.calls: List[Dict[str, Any]] = []

    def calculate(self, payload: Dict[str, Any], timeout=None) -> Dict[str, Any]:
        self.calls.append(payload)
        stages = payload.get("stages") or []
        whole = "all" in stages or "full" in stages
        stage_results: Dict[str, Any] = {}
        if whole or "calc" in stages:
            stage_results["calc"] = REF_CALC
        if whole or "teo" in stages:
            stage_results["teo"] = {"calc": REF_CALC, "consumption": REF_CONSUMPTION,
                                    "shape": {"kind": "rect", "w": 50.0, "h": 30.0,
                                              "area": 1500.0, "efficiency": 1.0},
                                    "teo": REF_TEO,
                                    "comparison": {"bestIndex": 0,
                                                   "bestCostPer1000": 704.88,
                                                   "baseCostPer1000": 704.88,
                                                   "savingsPer1000": 0.0,
                                                   "savingsPct": 0.0, "compared": 10},
                                    "best": {"costPer1000": 704.88, "rotated": False,
                                             "rows": 9, "cols": 5}}
        return {
            "schemaVersion": 2,
            "stages": stages,
            "stageResults": stage_results,
            "state": REF_STATE,
            "consumption": REF_CONSUMPTION,
            "teo": REF_TEO,
            "metrics": {"workerVersion": "0.1.0", "schemaVersion": 2,
                        "requestedStages": stages, "executedStages": stages,
                        "totalMs": 13, "reference": REFERENCE,
                        "counting": {"rows": 9, "cols": 5, "revs": 112,
                                     "count": 5040, "lengthMm": 34137.6,
                                     "rapportMm": 304.8, "wastePct": 26.18,
                                     "perLabelAreaMm2": 2032.0}},
        }

    def reports(self, payload: Dict[str, Any], timeout=None) -> Dict[str, Any]:
        """`POST /reports` (§12.8): цепочка + фейковый отчёт в base64."""
        result = self.calculate(payload, timeout=timeout)
        fmt = (payload.get("report") or {}).get("format") or "pdf"
        content = _FAKE_REPORT[fmt]
        result.setdefault("stageResults", {})["report"] = {
            "format": fmt,
            "name": f"fake-report.{fmt}",
            "mime": _FAKE_REPORT_MIME[fmt],
            "size": len(content),
            "contentBase64": base64.b64encode(content).decode("ascii"),
        }
        return result


# Байты «отчётов» для фейка воркера (структура проверяется в
# services/domain-worker/test/report_stage_test.dart, здесь — транспорт).
_FAKE_REPORT: Dict[str, bytes] = {
    "pdf": b"%PDF-1.4\n1 0 obj\n<< /Type /Catalog >>\nendobj\n%%EOF\n",
    "xlsx": b"PK\x03\x04" + b"\x00" * 64,
    "dxf": b"0\nSECTION\n2\nENTITIES\n0\nENDSEC\n0\nEOF\n",
}
_FAKE_REPORT_MIME: Dict[str, str] = {
    "pdf": "application/pdf",
    "xlsx": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
    "dxf": "application/dxf",
}


def _principal(orgs, user_id="user-1", email="user@example.com") -> Principal:
    return Principal(user_id=user_id, email=email,
                     orgs=[Membership(o, r) for o, r in orgs])


@pytest.fixture()
def env(monkeypatch):
    """Рантайм на временной БД + memory-хранилище + фейки auth/domain."""
    tmp = tempfile.mkdtemp(prefix="pp_api_domain_")
    cfg = Config({
        "PP_DATA_DIR": tmp,
        "PP_AUTH_URL": "http://auth.test:8121",
        "PP_BILLING_URL": "http://billing.test:8122",
        "CONVERTER_URL": "http://converter.test:8120",
        "DOMAIN_WORKER_URL": "http://domain-worker.test:8101",
        "OBJECT_STORAGE_ENDPOINT": "http://minio.test:9000",
        "OBJECT_STORAGE_BUCKET": "prepress-saas",
        "OBJECT_STORAGE_ACCESS_KEY": "test-key",
        "OBJECT_STORAGE_SECRET_KEY": "test-secret",
        "PP_STORAGE_BACKEND": "memory",
        "PP_AUTH_REQUIRED": "1",
        "PP_ENTITLEMENT_ENFORCE": "0",
    })
    cfg.verifier = FakeVerifier({
        TOKEN_A: _principal([(TENANT_A, "owner")], "user-a", "a@example.com"),
        TOKEN_B: _principal([(TENANT_B, "owner")], "user-b", "b@example.com"),
    })
    runtime = api_main.build_runtime(cfg)
    runtime["storage"] = MemoryObjectStorage()
    runtime["repo"] = repo_mod.Repo(runtime["db"], runtime["storage"],
                                    key_prefix="org", max_versions=3)
    runtime["domain"] = FakeDomain()
    runtime["storage_status"] = "memory"
    api_main.STATE.update(runtime)
    api_main.STATE["jobs"].clear()
    client = TestClient(api_main.app)
    yield client
    api_main.STATE.update({"config": None, "db": None, "storage": None,
                           "repo": None, "converter": None, "domain": None})


def _headers(token: str = TOKEN_A) -> Dict[str, str]:
    return {"Authorization": f"Bearer {token}"}


def _project(client: TestClient, token: str = TOKEN_A) -> str:
    resp = client.post("/api/projects", json={"name": "Проект"}, headers=_headers(token))
    assert resp.status_code == 201, resp.text
    return resp.json()["project_id"]


def _layout_params() -> Dict[str, Any]:
    """`layout_params` §12.6 (snake_case) — эталон PRD §10.2."""
    return {"label_w": 50, "label_h": 30, "gap_x": 3, "gap_y": 3,
            "z_teeth": 96, "cp": 3.175, "cyl_width": 300, "web_width": 300,
            "mode": "count", "count": 5000}


def _teo_input() -> Dict[str, Any]:
    return {"material_id": "paper-sa-80", "machine_id": "flexo-300"}


# --- перевод контракта §12.6 → wire-схема воркера --------------------------

def test_layout_params_snake_to_camel():
    """`layout_params` (§12.6) → `params` воркера (`project_state.json v2`)."""
    params = normalize_layout_params(_layout_params())
    assert params == {"labelW": 50.0, "labelH": 30.0, "gapX": 3.0, "gapY": 3.0,
                      "zTeeth": 96, "cp": 3.175, "cylWidth": 300.0,
                      "webWidth": 300.0, "mode": "count", "count": 5000}


def test_layout_params_camel_passthrough():
    """camelCase-схема состояния проекта принимается как есть."""
    camel = {"labelW": 50, "labelH": 30, "zTeeth": 96, "mode": "count", "count": 5000}
    assert normalize_layout_params(camel) == camel


def test_teo_input_snake_to_camel():
    teo = normalize_teo_input({"material_id": "paper-sa-80", "machine_id": "flexo-300",
                               "tooling_cost": 0, "markup_pct": 0,
                               "hours_per_shift": 8, "shifts_per_day": 1})
    assert teo == {"materialId": "paper-sa-80", "machineId": "flexo-300",
                   "toolingCost": 0, "markupPct": 0, "hoursPerShift": 8,
                   "shiftsPerDay": 1}


def test_build_payload_stages_and_defaults():
    payload = DomainClient("http://dw:8101").build_payload(
        stages=("all",), params=_layout_params(), teo_input=_teo_input(),
        variants_limit=10)
    assert payload["stages"] == ["all"]
    assert payload["params"]["labelW"] == 50.0
    assert payload["teoInput"] == {"materialId": "paper-sa-80",
                                   "machineId": "flexo-300"}
    assert payload["variantsLimit"] == 10
    assert payload["includeRawPaths"] is False
    assert payload["includeErrors"] is True
    assert "file_base64" not in payload


# --- эндпоинты расчёта (§12.6) ---------------------------------------------

def test_calc_returns_reference_numbers(env):
    """`POST /projects/{id}/calc` → эталон раскроя PRD §10.2 (N-1)."""
    pid = _project(env)
    resp = env.post(f"/api/projects/{pid}/calc",
                    json={"layout_params": _layout_params()}, headers=_headers())
    assert resp.status_code == 200, resp.text
    body = resp.json()
    calc = body["calc"]
    assert (calc["rows"], calc["cols"]) == (9, 5)
    assert calc["count"] == 5040
    assert calc["revs"] == 112
    assert calc["length"] == 34137.6
    assert calc["wastePct"] == 26.18
    assert calc["perLabelArea"] == 2032.0
    assert calc["rapport"] == 304.8
    assert body["reference"]["delta"]["wastePct"] == 0.0


def test_pipeline_returns_state_with_reference(env):
    """`POST /projects/{id}/pipeline` → `state` + метрики эталона (§12.6)."""
    pid = _project(env)
    resp = env.post(f"/api/projects/{pid}/pipeline",
                    json={"layout_params": _layout_params(),
                          "teo_input": _teo_input()}, headers=_headers())
    assert resp.status_code == 200, resp.text
    body = resp.json()
    state = body["state"]
    assert state["schemaVersion"] == 2
    assert state["calc"]["rows"] == 9 and state["calc"]["cols"] == 5
    assert state["calc"]["count"] == 5040
    assert body["result"]["teo"]["costPer1000"] == 704.88
    assert body["reference"]["passed"] is True


def test_calculate_alias_matches_pipeline(env):
    """`/calculate` — синоним `/pipeline` (UI-путь «рассчитать»)."""
    pid = _project(env)
    body = {"layout_params": _layout_params(), "teo_input": _teo_input()}
    a = env.post(f"/api/projects/{pid}/pipeline", json=body, headers=_headers())
    b = env.post(f"/api/projects/{pid}/calculate", json=body, headers=_headers())
    assert a.status_code == 200 and b.status_code == 200
    assert a.json()["state"]["calc"] == b.json()["state"]["calc"]


def test_pipeline_accepts_api_v1_path(env):
    """§12.4-путь `/api/v1/...` нормализуется middleware (nginx срезает /api)."""
    pid = _project(env)
    resp = env.post(f"/api/v1/projects/{pid}/calc",
                    json={"layout_params": _layout_params()}, headers=_headers())
    assert resp.status_code == 200, resp.text
    assert resp.json()["calc"]["count"] == 5040


def test_variants_returns_list(env):
    """`POST /projects/{id}/variants` → перебор вариантов (F-11)."""
    pid = _project(env)
    resp = env.post(f"/api/projects/{pid}/variants",
                    json={"layout_params": _layout_params(), "limit": 10},
                    headers=_headers())
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["total"] == len(body["variants"]) == 2
    assert body["variants"][0]["perLabelArea"] == 2032.0
    assert body["selected_variant_index"] == 0


def test_teo_returns_cost_per_1000(env):
    """`POST /projects/{id}/teo` → `costPer1000 = 704.88` (§12.6, F-14)."""
    pid = _project(env)
    resp = env.post(f"/api/projects/{pid}/teo",
                    json={"layout_params": _layout_params(),
                          "teo_input": _teo_input()}, headers=_headers())
    assert resp.status_code == 200, resp.text
    teo = resp.json()["teo"]
    assert teo["costPer1000"] == 704.88
    assert teo["totalCost"] == 3552.58
    assert teo["machineCost"] == 2528.45
    assert teo["materialCost"] == 1024.13
    assert teo["runTimeHours"] == 0.0057


def test_teo_requires_material_and_machine(env):
    pid = _project(env)
    no_input = env.post(f"/api/projects/{pid}/teo",
                        json={"layout_params": _layout_params()}, headers=_headers())
    assert no_input.status_code == 422
    assert no_input.json()["error"]["code"] == "teo_input_required"
    no_material = env.post(f"/api/projects/{pid}/teo",
                           json={"layout_params": _layout_params(),
                                 "teo_input": {"machine_id": "flexo-300"}},
                           headers=_headers())
    assert no_material.status_code == 422
    assert no_material.json()["error"]["code"] == "material_required"


def test_teo_compare_returns_comparison(env):
    """`POST /projects/{id}/teo/compare` → экономия лучшего (§12.6, F-15)."""
    pid = _project(env)
    resp = env.post(f"/api/projects/{pid}/teo/compare",
                    json={"layout_params": _layout_params(),
                          "teo_input": _teo_input()}, headers=_headers())
    assert resp.status_code == 200, resp.text
    comparison = resp.json()["comparison"]
    assert comparison["bestIndex"] == 0
    assert comparison["bestCostPer1000"] == 704.88
    assert comparison["savingsPer1000"] == 0.0


# --- изоляция тенантов (N-4) и авторизация ---------------------------------

def test_domain_requires_token(env):
    pid = _project(env)
    resp = env.post(f"/api/projects/{pid}/calc",
                    json={"layout_params": _layout_params()})
    assert resp.status_code == 401


def test_domain_other_tenant_project_is_404(env):
    """Чужой проект недоступен даже при знании id (N-4)."""
    pid = _project(env, TOKEN_A)
    resp = env.post(f"/api/projects/{pid}/pipeline",
                    json={"layout_params": _layout_params()},
                    headers=_headers(TOKEN_B))
    assert resp.status_code == 404
    assert resp.json()["error"]["code"] == "project_not_found"


def test_domain_does_not_call_worker_for_foreign_project(env):
    """Изоляция проверяется ДО вызова воркера (домен не получает чужой проект)."""
    pid = _project(env, TOKEN_A)
    fake = api_main.STATE["domain"]
    env.post(f"/api/projects/{pid}/calc", json={"layout_params": _layout_params()},
             headers=_headers(TOKEN_B))
    assert fake.calls == []


# --- байты макета (F-1) ----------------------------------------------------

def test_file_version_bytes_are_sent_base64(env):
    """`file_version_id` → байты объекта в base64 для воркера (F-1)."""
    pid = _project(env)
    dxf = (FIXTURES / "quadroring.dxf").read_bytes()
    up = env.post(f"/api/projects/{pid}/files",
                  files={"file": ("quadroring.dxf", dxf, "application/octet-stream")},
                  headers=_headers())
    assert up.status_code == 201, up.text
    file_id = up.json()["file_id"]

    resp = env.post(f"/api/projects/{pid}/pipeline",
                    json={"file_id": file_id, "layout_params": _layout_params()},
                    headers=_headers())
    assert resp.status_code == 200, resp.text
    payload = api_main.STATE["domain"].calls[-1]
    assert payload["fileName"] == "quadroring.dxf"
    assert base64.b64decode(payload["file_base64"]) == dxf


def test_unknown_file_version_is_404(env):
    pid = _project(env)
    resp = env.post(f"/api/projects/{pid}/pipeline",
                    json={"file_version_id": "нет-такой-версии",
                          "layout_params": _layout_params()},
                    headers=_headers())
    assert resp.status_code == 404
    assert resp.json()["error"]["code"] == "version_not_found"


# --- отказ воркера транслируется русским сообщением (F-4) ------------------

class _FailingDomain(FakeDomain):
    def calculate(self, payload, timeout=None):
        raise DomainError("Неизвестная стадия «мусор». Доступные: parse, analyze.",
                          status=422, code="domain_bad_request")


def test_worker_error_is_translated(env):
    api_main.STATE["domain"] = _FailingDomain()
    pid = _project(env)
    resp = env.post(f"/api/projects/{pid}/calc",
                    json={"layout_params": _layout_params()}, headers=_headers())
    assert resp.status_code == 422
    body = resp.json()["error"]
    assert body["code"] == "domain_bad_request"
    assert "Неизвестная стадия" in body["message"]


class _UnavailableDomain(FakeDomain):
    def calculate(self, payload, timeout=None):
        raise DomainError("Сервис расчётов (domain-worker) недоступен: refused.",
                          status=503, code="domain_unavailable")


def test_worker_unavailable_is_503(env):
    api_main.STATE["domain"] = _UnavailableDomain()
    pid = _project(env)
    resp = env.post(f"/api/projects/{pid}/calc",
                    json={"layout_params": _layout_params()}, headers=_headers())
    assert resp.status_code == 503
    assert resp.json()["error"]["code"] == "domain_unavailable"


# --- отчёты (§12.8): POST /projects/{id}/reports/{fmt} ----------------------

def test_reports_pdf_stores_and_streams(env):
    """PDF: воркер → base64 → хранилище → скачивание потоком."""
    pid = _project(env)
    resp = env.post(f"/api/projects/{pid}/reports/pdf",
                    json={"layout_params": _layout_params(),
                          "teo_input": _teo_input(),
                          "font_base64": base64.b64encode(b"TTF-bytes").decode()},
                    headers=_headers())
    assert resp.status_code == 200, resp.text
    body = resp.json()
    rep = body["report"]
    assert body["project_id"] == pid
    assert rep["kind"] == "pdf"
    assert rep["size_bytes"] == len(_FAKE_REPORT["pdf"])
    assert body["download"] == f"/reports/{rep['id']}/download"

    dl = env.get(f"/api{body['download']}", headers=_headers())
    assert dl.status_code == 200
    assert dl.content == _FAKE_REPORT["pdf"]
    assert dl.headers["content-type"].startswith("application/pdf")


def test_reports_payload_translation_and_stages(env):
    """Перевод §12.6 → воркер: camelCase params, секция report, fontBase64."""
    pid = _project(env)
    env.post(f"/api/projects/{pid}/reports/xlsx",
             json={"layout_params": _layout_params()}, headers=_headers())
    fake = api_main.STATE["domain"]
    payload = fake.calls[-1]
    assert payload["report"]["format"] == "xlsx"
    assert payload["report"]["paths"] == "master"
    assert "fontBase64" not in payload["report"]
    # Без макета/геометрии — расчётная часть цепочки.
    assert payload["stages"] == ["calc", "variants", "teo"]
    assert payload["params"]["labelW"] == 50.0  # snake_case → camelCase


def test_reports_with_state_geometry_uses_all_stages(env):
    """state с rawPaths → стадии all (нужны heal/pattern для DXF)."""
    pid = _project(env)
    state = {"name": "Макет", "rawPaths": [
        {"points": [[0, 0], [50, 0], [50, 30], [0, 30]], "closed": True}]}
    resp = env.post(f"/api/projects/{pid}/reports/dxf",
                    json={"layout_params": _layout_params(),
                          "state": state, "paths": "array"},
                    headers=_headers())
    assert resp.status_code == 200, resp.text
    payload = api_main.STATE["domain"].calls[-1]
    assert payload["stages"] == ["all"]
    assert payload["state"] == state
    assert payload["report"]["paths"] == "array"
    assert payload["report"]["format"] == "dxf"


def test_reports_invalid_format_422(env):
    pid = _project(env)
    resp = env.post(f"/api/projects/{pid}/reports/docx",
                    json={"layout_params": _layout_params()}, headers=_headers())
    assert resp.status_code == 422
    err = resp.json()["error"]
    assert err["code"] == "invalid_format"
    assert "pdf, xlsx или dxf" in err["message"]


def test_reports_cross_tenant_403(env):
    """Чужой проект недоступен даже при знании id (N-4)."""
    pid = _project(env)  # TENANT_A
    resp = env.post(f"/api/projects/{pid}/reports/pdf",
                    json={"layout_params": _layout_params()},
                    headers=_headers(TOKEN_B))
    assert resp.status_code in (403, 404)


class _ReportFailDomain(FakeDomain):
    def reports(self, payload, timeout=None):
        raise DomainError("Шрифт для кириллицы не найден: передайте "
                          "report.fontBase64 либо задайте PP_FONT_PATH.",
                          status=400, code="bad_request")


def test_reports_domain_error_translates(env):
    """Ошибка воркера (например, шрифт) уходит клиенту как есть (§12.1)."""
    api_main.STATE["domain"] = _ReportFailDomain()
    pid = _project(env)
    resp = env.post(f"/api/projects/{pid}/reports/pdf",
                    json={"layout_params": _layout_params()}, headers=_headers())
    assert resp.status_code == 400
    err = resp.json()["error"]
    assert err["code"] == "bad_request"
    assert "Шрифт" in err["message"]
