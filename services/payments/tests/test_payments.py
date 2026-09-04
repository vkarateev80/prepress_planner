# -*- coding: utf-8 -*-
"""Тесты микросервиса оплаты (заглушка).

Проверка токена в payments идёт через auth (HTTP); в тестах подменяется
фейком verify_token — сервисы не гоняются по сети.
"""
import os
import sys
import tempfile
import time
from pathlib import Path

import pytest

_tmp = tempfile.mkdtemp(prefix="pp_pay_test_")
os.environ["PP_DATA_DIR"] = _tmp
os.environ["PP_AUTH_URL"] = "http://auth.test:8121"  # не используется (фейк)

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

import payments_app.main as pm  # noqa: E402

from fastapi.testclient import TestClient  # noqa: E402

from payments_app.main import app  # noqa: E402
from payments_app.main import PLANS  # noqa: E402

client = TestClient(app)

# Фейковая проверка токена: токен "token-<id>" → claims.
_FAKE = {"user-a": "user-a", "user-b": "user-b", "user-ext": "user-ext",
         "user-web": "user-web", "user-1": "user-1"}


@pytest.fixture(autouse=True)
def _fake_verify(monkeypatch):
    def fake(token):
        key = token.removeprefix("token-")
        if key not in _FAKE:
            from fastapi import HTTPException
            raise HTTPException(status_code=401, detail="bad token")
        return {"sub": _FAKE[key], "email": f"{key}@example.com"}

    monkeypatch.setattr(pm, "verify_token", fake)


def _auth(token: str) -> dict:
    return {"Authorization": f"Bearer {token}"}


def test_healthz():
    r = client.get("/healthz")
    assert r.status_code == 200
    assert "month" in r.json()["plans"]


def test_checkout_requires_token():
    r = client.post("/payments/checkout", json={"plan": "month"})
    assert r.status_code == 401


def test_checkout_confirm_subscription_flow():
    h = _auth("token-user-1")
    r = client.post("/payments/checkout", json={"plan": "month"}, headers=h)
    assert r.status_code == 200, r.text
    order = r.json()
    assert order["status"] == "pending"
    assert order["amount_rub"] == PLANS["month"]["price_rub"]
    oid = order["order_id"]

    r = client.get("/payments/subscription", headers=h)
    assert r.json() == {"plan": None, "pro": False, "until": None}

    r = client.post(f"/payments/orders/{oid}/confirm", headers=h)
    assert r.status_code == 200, r.text
    assert r.json()["plan"] == "month"

    sub = client.get("/payments/subscription", headers=h).json()
    assert sub["pro"] is True
    assert sub["plan"] == "month"
    assert sub["until"] > time.time()

    r = client.post(f"/payments/orders/{oid}/confirm", headers=h)
    assert r.status_code == 409


def test_chained_subscription_extends():
    h = _auth("token-user-ext")
    oid1 = client.post("/payments/checkout", json={"plan": "month"},
                       headers=h).json()["order_id"]
    client.post(f"/payments/orders/{oid1}/confirm", headers=h)
    first = client.get("/payments/subscription", headers=h).json()["until"]

    oid2 = client.post("/payments/checkout", json={"plan": "year"},
                       headers=h).json()["order_id"]
    client.post(f"/payments/orders/{oid2}/confirm", headers=h)
    second = client.get("/payments/subscription", headers=h).json()
    expect = first + PLANS["year"]["days"] * 86400
    assert abs(second["until"] - expect) < 2


def test_foreign_order_404():
    h1 = _auth("token-user-a")
    h2 = _auth("token-user-b")
    oid = client.post("/payments/checkout", json={"plan": "month"},
                      headers=h1).json()["order_id"]
    r = client.post(f"/payments/orders/{oid}/confirm", headers=h2)
    assert r.status_code == 404


def test_webhook_stub():
    h = _auth("token-user-web")
    oid = client.post("/payments/checkout", json={"plan": "year"},
                      headers=h).json()["order_id"]
    r = client.post("/payments/webhook", json={"order_id": oid})
    assert r.status_code == 200
    sub = client.get("/payments/subscription", headers=h).json()
    assert sub["plan"] == "year" and sub["pro"] is True


def test_bad_plan():
    h = _auth("token-user-1")
    r = client.post("/payments/checkout", json={"plan": "decade"}, headers=h)
    assert r.status_code == 422


def test_revoked_token_rejected():
    """Отозванная auth-сессия: payments отвечает 401 (имитация HTTPError)."""
    from fastapi import HTTPException

    def denied(token):
        raise HTTPException(status_code=401, detail="сессия не найдена")

    pm.verify_token = denied
    h = _auth("token-user-1")
    r = client.post("/payments/checkout", json={"plan": "month"}, headers=h)
    assert r.status_code == 401
