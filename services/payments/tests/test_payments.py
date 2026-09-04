# -*- coding: utf-8 -*-
"""Тесты микросервиса оплаты (заглушка)."""
import os
import sys
import tempfile
import time
from pathlib import Path

import pytest

_tmp = tempfile.mkdtemp(prefix="pp_pay_test_")
os.environ["PP_DATA_DIR"] = _tmp
os.environ["PP_AUTH_SECRET"] = "test-secret-0123456789abcdef"

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from fastapi.testclient import TestClient  # noqa: E402

from payments_app.main import app  # noqa: E402
from payments_app.main import PLANS  # noqa: E402

client = TestClient(app)

# Токен «от auth» с тем же секретом (алгоритм идентичен).
def _token(user_id="user-1", email="u@example.com") -> str:
    import hashlib
    import hmac
    import json
    body = json.dumps({
        "sub": user_id, "email": email,
        "exp": int(time.time()) + 3600,
    }, separators=(",", ":")).encode()
    sig = hmac.new(os.environ["PP_AUTH_SECRET"].encode(), body,
                   hashlib.sha256).hexdigest()
    return f"{sig}.{body.decode()}"


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
    h = _auth(_token())
    r = client.post("/payments/checkout", json={"plan": "month"}, headers=h)
    assert r.status_code == 200, r.text
    order = r.json()
    assert order["status"] == "pending"
    assert order["amount_rub"] == PLANS["month"]["price_rub"]
    oid = order["order_id"]

    # Подписки ещё нет.
    r = client.get("/payments/subscription", headers=h)
    assert r.json() == {"plan": None, "pro": False, "until": None}

    # Подтверждение тестовой оплаты.
    r = client.post(f"/payments/orders/{oid}/confirm", headers=h)
    assert r.status_code == 200, r.text
    assert r.json()["plan"] == "month"

    sub = client.get("/payments/subscription", headers=h).json()
    assert sub["pro"] is True
    assert sub["plan"] == "month"
    assert sub["until"] > time.time()

    # Повторное подтверждение — 409.
    r = client.post(f"/payments/orders/{oid}/confirm", headers=h)
    assert r.status_code == 409


def test_chained_subscription_extends():
    """Год после месяца продлевается от конца, а не от сейчас."""
    h = _auth(_token("user-ext"))
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
    """Чужой заказ чужому пользователю не виден."""
    h1 = _auth(_token("user-a"))
    h2 = _auth(_token("user-b"))
    oid = client.post("/payments/checkout", json={"plan": "month"},
                      headers=h1).json()["order_id"]
    r = client.post(f"/payments/orders/{oid}/confirm", headers=h2)
    assert r.status_code == 404


def test_webhook_stub():
    h = _auth(_token("user-web"))
    oid = client.post("/payments/checkout", json={"plan": "year"},
                      headers=h).json()["order_id"]
    r = client.post("/payments/webhook", json={"order_id": oid})
    assert r.status_code == 200
    sub = client.get("/payments/subscription", headers=h).json()
    assert sub["plan"] == "year" and sub["pro"] is True


def test_bad_plan():
    h = _auth(_token())
    r = client.post("/payments/checkout", json={"plan": "decade"}, headers=h)
    assert r.status_code == 422
