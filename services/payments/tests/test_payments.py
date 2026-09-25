# -*- coding: utf-8 -*-
"""Тесты billing-сервиса (ЮKassa + webhook/entitlement, ADR-3).

Проверяется:
  * тарифы и checkout (заказ pending + confirmation_url, без платёжных секретов);
  * вебхук с проверкой HMAC-SHA256 подписи (и отказ без секрета — fail closed);
  * идемпотентность обработки по `provider_payment_id` (UNIQUE) и продление
    подписки от конца текущего периода;
  * триал 15 дней вне провайдера: `trial_active` → Free (после окончания) →
    Pro (после оплаты);
  * отмена/возобновление автопродления и возврат (только owner/admin);
  * изоляция тенантов по `org_id` и отсутствие legacy-заглушки (`/confirm`).

Токены не гоняются по сети: `verify_token` подменяется фейком, возвращающим
`{sub, email, orgs:[{org_id, role}]}` как это делает auth `POST /auth/verify`.
Провайдер тоже фейковый (`PaymentProvider`), но подпись и разбор уведомления
используют ПРОДАКШН-код (`verify_webhook_signature`, `normalize_event`).
"""
import hashlib
import hmac
import json
import os
import sys
import tempfile
import time
from pathlib import Path
from typing import Any, Dict, List, Optional

import pytest

_TMP = tempfile.mkdtemp(prefix="pp_billing_test_")
os.environ["PP_DATA_DIR"] = _TMP
os.environ["PP_AUTH_URL"] = "http://auth.test:8121"  # не используется (фейк)
os.environ["PP_TRIAL_DAYS"] = "15"
os.environ["YUKASSA_WEBHOOK_SECRET"] = "test-webhook-secret"
os.environ["PP_PRO_MONTH_PRICE_RUB"] = "990"
os.environ["PP_PRO_YEAR_PRICE_RUB"] = "9900"
# По умолчанию — SQLite в PP_DATA_DIR; PP_TEST_DB_URL позволяет прогнать ту же
# сюиту против реального PostgreSQL (проверка совместимости схемы, System Design §13).
if os.environ.get("PP_TEST_DB_URL"):
    os.environ["DB_URL"] = os.environ["PP_TEST_DB_URL"]
else:
    os.environ.pop("DB_URL", None)
os.environ.pop("YUKASSA_SHOP_ID", None)
os.environ.pop("YUKASSA_SECRET_KEY", None)

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from fastapi import HTTPException  # noqa: E402
from fastapi.testclient import TestClient  # noqa: E402

import payments_app.main as pm  # noqa: E402
from payments_app import store as store_mod  # noqa: E402
from payments_app.main import STORE, app  # noqa: E402
from payments_app.provider import (PaymentProvider, UnconfiguredProvider,  # noqa: E402
                                   normalize_event, verify_webhook_signature)

WEBHOOK_SECRET = "test-webhook-secret"
client = TestClient(app)


# --------------------------------------------------------------------------
# Фейки: auth и платёжный провайдер
# --------------------------------------------------------------------------

def fake_verify(token: str) -> Dict[str, Any]:
    """Токен вида `t:<org|org2>:<role>` → выдача auth /auth/verify."""
    if not token.startswith("t:"):
        raise HTTPException(status_code=401, detail="Недействительный токен")
    _, orgs_raw, role = token.split(":", 2)
    orgs = []
    if orgs_raw and orgs_raw not in ("-", "noorg"):
        for org_id in orgs_raw.split("|"):
            orgs.append({"org_id": org_id, "role": role})
    return {"sub": f"user-{orgs_raw}", "email": f"{orgs_raw}@example.com",
            "orgs": orgs}


def auth(token: str) -> Dict[str, str]:
    return {"Authorization": f"Bearer {token}"}


class FakeYooKassa(PaymentProvider):
    """Фейковый ЮKassa: без сети, но с реальной проверкой подписи и разбором."""

    name = "yookassa-fake"

    def __init__(self, store: store_mod.BillingStore, webhook_secret: str = WEBHOOK_SECRET):
        super().__init__(store)
        self.webhook_secret = webhook_secret
        self.created: List[Dict[str, Any]] = []
        self.refunds: List[Dict[str, Any]] = []
        self.refund_status = "succeeded"
        self.fail_create = False

    def create_payment(self, order: Dict[str, Any], plan: Dict[str, Any],
                       return_url: str = "") -> Dict[str, Any]:
        if self.fail_create:
            from payments_app.provider import ProviderError
            raise ProviderError("ЮKassa недоступна: тестовый сбой")
        payment_id = f"pay-{order['id']}"
        self.created.append({"order_id": order["id"], "plan": plan["plan"],
                             "amount_rub": order["amount_rub"],
                             "return_url": return_url})
        return {"provider_payment_id": payment_id, "provider_order_id": payment_id,
                "status": "pending",
                "confirmation_url": f"https://yookassa.test/confirm/{payment_id}"}

    def process_webhook(self, raw_body: bytes, headers) -> Dict[str, Any]:
        verify_webhook_signature(raw_body, headers, self.webhook_secret)
        return normalize_event(json.loads(raw_body.decode("utf-8")))

    def refund(self, payment_id: str, amount_rub: int, order_id: str = "",
               idempotence_key: str = "") -> Dict[str, Any]:
        refund_id = f"refund-{payment_id}"
        self.refunds.append({"payment_id": payment_id, "amount_rub": amount_rub,
                             "order_id": order_id, "idempotence_key": idempotence_key})
        return {"refund_id": refund_id, "status": self.refund_status,
                "raw": {"id": refund_id, "payment_id": payment_id,
                        "status": self.refund_status}}


@pytest.fixture(scope="session", autouse=True)
def _clean_tables():
    """Чистое состояние billing на каждый прогон (SQLite и PostgreSQL).

    Организации в тестах имеют фиксированные имена; без очистки повторный прогон
    против постоянной БД (PostgreSQL) накапливал бы подписки и транзакции.
    """
    with STORE.db.tx() as conn:
        for table in ("transactions", "orders", "entitlements", "subscriptions"):
            conn.execute(f"DELETE FROM {table}")
    yield


@pytest.fixture()
def fake_provider() -> FakeYooKassa:
    provider = FakeYooKassa(STORE)
    app.dependency_overrides[pm.get_provider] = lambda: provider
    yield provider
    app.dependency_overrides.clear()


@pytest.fixture(autouse=True)
def _fake_auth(monkeypatch):
    monkeypatch.setattr(pm, "verify_token", fake_verify)


# --------------------------------------------------------------------------
# Помощники
# --------------------------------------------------------------------------

def payment_event(payment_id: str, order_id: str, org_id: str, plan: str = "month",
                  amount: str = "990.00", event: str = "payment.succeeded",
                  status: str = "succeeded", paid: bool = True) -> Dict[str, Any]:
    return {
        "type": "notification",
        "event": event,
        "object": {
            "id": payment_id,
            "status": status,
            "paid": paid,
            "amount": {"value": amount, "currency": "RUB"},
            "metadata": {"order_id": order_id, "org_id": org_id, "plan": plan},
            "payment_method": {"id": "pm-1", "saved": True},
        },
    }


def refund_event(refund_id: str, payment_id: str, amount: str = "990.00") -> Dict[str, Any]:
    return {
        "type": "notification",
        "event": "refund.succeeded",
        "object": {
            "id": refund_id,
            "payment_id": payment_id,
            "status": "succeeded",
            "amount": {"value": amount, "currency": "RUB"},
        },
    }


def post_webhook(payload: Dict[str, Any], secret: Optional[str] = WEBHOOK_SECRET,
                 headers: Optional[Dict[str, str]] = None):
    body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
    head = {"Content-Type": "application/json"}
    if secret is not None:
        head["X-Signature"] = hmac.new(secret.encode("utf-8"), body,
                                       hashlib.sha256).hexdigest()
    head.update(headers or {})
    return client.post("/payments/webhook", content=body, headers=head)


def checkout(token: str, plan: str = "month", org_id: Optional[str] = None) -> Dict[str, Any]:
    payload: Dict[str, Any] = {"plan": plan}
    if org_id:
        payload["org_id"] = org_id
    response = client.post("/payments/checkout", json=payload, headers=auth(token))
    assert response.status_code == 200, response.text
    return response.json()


def pay(token: str, plan: str = "month", org_id: Optional[str] = None,
        amount: Optional[str] = None) -> Dict[str, Any]:
    """Полный happy-path: checkout → вебхук payment.succeeded."""
    order = checkout(token, plan, org_id)
    org = order["org_id"]
    payment_id = f"pay-{order['order_id']}"
    value = amount or f"{order['amount_rub']}.00"
    response = post_webhook(payment_event(payment_id, order["order_id"], org, plan, value))
    assert response.status_code == 200, response.text
    return order


def subscription(token: str, org_id: Optional[str] = None) -> Dict[str, Any]:
    params = {"org_id": org_id} if org_id else None
    response = client.get("/payments/subscription", headers=auth(token), params=params)
    assert response.status_code == 200, response.text
    return response.json()


def entitlement(token: str, org_id: Optional[str] = None) -> Dict[str, Any]:
    params = {"org_id": org_id} if org_id else None
    response = client.get("/payments/entitlement", headers=auth(token), params=params)
    assert response.status_code == 200, response.text
    return response.json()


def set_trial_end(org_id: str, iso: str) -> None:
    with STORE.db.tx() as conn:
        conn.execute("UPDATE subscriptions SET trial_ends_at = ? WHERE org_id = ?",
                     (iso, org_id))


# --------------------------------------------------------------------------
# Health и тарифы
# --------------------------------------------------------------------------

def test_healthz(fake_provider):
    response = client.get("/healthz")
    assert response.status_code == 200, response.text
    body = response.json()
    assert body["status"] == "ok"
    assert body["service"] == "billing"
    assert body["provider"] == pm.PROVIDER.name  # активный провайдер процесса
    assert body["configured"] is False  # ключей ЮKassa в этой среде нет
    assert body["trial_days"] == 15
    assert body["db"]["ok"] is True
    # Драйвер выбирается по DB_URL: SQLite (по умолчанию) или PostgreSQL.
    assert body["db"]["target"].startswith(("sqlite:", "postgresql:"))


def test_plans_month_and_year():
    body = client.get("/payments/plans").json()
    plans = {p["plan"]: p for p in body}
    assert plans["month"]["amount_rub"] == 990 and plans["month"]["days"] == 30
    assert plans["year"]["amount_rub"] == 9900 and plans["year"]["days"] == 365
    assert plans["month"]["currency"] == "RUB"


def test_free_plan_features():
    body = client.get("/payments/free-plan").json()
    assert body["features"] == {"projects": 1, "teo": False, "reports": False}


# --------------------------------------------------------------------------
# Checkout
# --------------------------------------------------------------------------

def test_checkout_requires_token(fake_provider):
    assert client.post("/payments/checkout", json={"plan": "month"}).status_code == 401


def test_checkout_creates_order_and_confirmation_url(fake_provider):
    order = checkout("t:org-checkout:owner")
    assert order["status"] == "pending"
    assert order["amount_rub"] == 990
    assert order["plan"] == "month"
    assert order["confirmation_url"].startswith("https://yookassa.test/confirm/")
    # Клиент не получает платёжных секретов, кодов и legacy-подсказок.
    assert "hint" not in order and "dev" not in json.dumps(order).lower()
    for secret in ("secret", "shop_id", "webhook"):
        assert secret not in json.dumps(order).lower()

    view = client.get(f"/payments/orders/{order['order_id']}",
                      headers=auth("t:org-checkout:owner")).json()
    assert view["status"] == "pending"
    assert view["status_alias"] == "pending"
    assert view["confirmation_url"] == order["confirmation_url"]
    assert "provider_order_id" not in view  # внутренние id не отдаём


def test_checkout_bad_plan(fake_provider):
    response = client.post("/payments/checkout", json={"plan": "decade"},
                           headers=auth("t:org-badplan:owner"))
    assert response.status_code == 422


def test_checkout_plan_alias_pro_month(fake_provider):
    order = checkout("t:org-alias:owner", "pro_year")
    assert order["plan"] == "year" and order["amount_rub"] == 9900


def test_checkout_without_provider_keys_returns_503():
    """Ключей ЮKassa нет — сервис не подменяет оплату «тестовым» режимом."""
    app.dependency_overrides[pm.get_provider] = lambda: UnconfiguredProvider(STORE)
    try:
        response = client.post("/payments/checkout", json={"plan": "month"},
                               headers=auth("t:org-nokeys:owner"))
        assert response.status_code == 503
        assert "ЮKassa не настроена" in response.json()["detail"]
        # Заказ создан, но помечен failed: подтверждения оплаты на сервере нет.
        with STORE.db.read() as conn:
            order = conn.query_one("SELECT status FROM orders WHERE org_id = ?",
                                   ("org-nokeys",))
            count = conn.query_one("SELECT COUNT(*) AS n FROM transactions")["n"]
        assert count == 0
        assert order["status"] == "failed"
    finally:
        app.dependency_overrides.clear()


def test_legacy_confirm_endpoint_removed(fake_provider):
    order = checkout("t:org-legacy:owner")
    response = client.post(f"/payments/orders/{order['order_id']}/confirm",
                           headers=auth("t:org-legacy:owner"))
    assert response.status_code == 404  # заглушка удалена


# --------------------------------------------------------------------------
# Вебхук
# --------------------------------------------------------------------------

def test_webhook_activates_subscription_and_entitlement(fake_provider):
    token = "t:org-activate:owner"
    order = pay(token)
    sub = subscription(token)
    assert sub["status"] == "active"
    assert sub["plan"] == "month" and sub["plan_alias"] == "pro_month"
    assert sub["pro"] is True and sub["trial_active"] is False
    assert sub["cancel_at_period_end"] is False
    until = store_mod.from_iso(sub["until"])
    assert until is not None and until > time.time() + 29 * 86400
    assert sub["current_period_ends_at"] == sub["current_period_end"]

    ent = entitlement(token)
    assert ent["plan"] == "pro" and ent["status"] == "pro" and ent["pro"] is True
    assert ent["features"] == {"projects": None, "teo": True, "reports": True}

    # Заказ помечен оплаченным («paid» = canonical, «succeeded» = alias task-spec).
    view = client.get(f"/payments/orders/{order['order_id']}", headers=auth(token)).json()
    assert view["status"] == "paid" and view["status_alias"] == "succeeded"
    assert view["paid_at"]


def test_webhook_is_idempotent(fake_provider):
    token = "t:org-idem:owner"
    order = pay(token)
    first = subscription(token)["until"]
    body = payment_event(f"pay-{order['order_id']}", order["order_id"],
                         order["org_id"])
    again = post_webhook(body)
    assert again.status_code == 200, again.text
    assert again.json().get("already") is True
    assert subscription(token)["until"] == first  # период не удвоился


def test_webhook_rejects_bad_signature(fake_provider):
    token = "t:org-badsig:owner"
    order = checkout(token)
    body = payment_event(f"pay-{order['order_id']}", order["order_id"], order["org_id"])
    response = post_webhook(body, secret="wrong-secret")
    assert response.status_code == 401
    assert subscription(token)["status"] == "trialing"


def test_webhook_rejects_missing_signature(fake_provider):
    token = "t:org-nosig:owner"
    order = checkout(token)
    body = payment_event(f"pay-{order['order_id']}", order["order_id"], order["org_id"])
    assert post_webhook(body, secret=None).status_code == 401


def test_webhook_fail_closed_without_secret():
    """Без YUKASSA_WEBHOOK_SECRET вебхук не принимается (никакого dev-режима)."""
    app.dependency_overrides[pm.get_provider] = lambda: FakeYooKassa(
        STORE, webhook_secret="")
    try:
        response = post_webhook(payment_event("pay-x", "order-x", "org-x"))
        assert response.status_code == 503
    finally:
        app.dependency_overrides.clear()


def test_webhook_unknown_order_404(fake_provider):
    response = post_webhook(payment_event("pay-unknown", "order-unknown", "org-unknown"))
    assert response.status_code == 404


def test_webhook_unknown_event_ignored(fake_provider):
    payload = payment_event("pay-ignored", "order-ignored", "org-ignored",
                            event="payment.waiting_for_capture", status="waiting_for_capture")
    response = post_webhook(payload)
    assert response.status_code == 200
    assert response.json().get("ignored") == "payment.waiting_for_capture"


def test_payment_canceled_marks_order_canceled(fake_provider):
    token = "t:org-canceled-pay:owner"
    order = checkout(token)
    payload = payment_event(f"pay-{order['order_id']}", order["order_id"],
                            order["org_id"], event="payment.canceled",
                            status="canceled", paid=False)
    assert post_webhook(payload).status_code == 200
    view = client.get(f"/payments/orders/{order['order_id']}", headers=auth(token)).json()
    assert view["status"] == "canceled"
    assert subscription(token)["pro"] is True  # права триала не тронуты
    assert subscription(token)["status"] == "trialing"


def test_renewal_extends_from_end_of_current_period(fake_provider):
    token = "t:org-chain:owner"
    pay(token, "month")
    first = store_mod.from_iso(subscription(token)["until"])
    pay(token, "year")
    second = store_mod.from_iso(subscription(token)["until"])
    assert second is not None and first is not None
    assert abs(second - (first + 365 * 86400)) < 5
    assert subscription(token)["plan"] == "year"


# --------------------------------------------------------------------------
# Триал
# --------------------------------------------------------------------------

def test_trial_is_created_lazily_for_new_org(fake_provider):
    token = "t:org-trial:owner"
    sub = subscription(token)
    assert sub["status"] == "trialing"
    assert sub["trial_active"] is True and sub["pro"] is True
    trial_end = store_mod.from_iso(sub["trial_ends_at"])
    assert trial_end is not None
    assert abs(trial_end - (time.time() + 15 * 86400)) < 60
    assert entitlement(token)["trial_active"] is True

    # Триал стартует один раз: повторный запрос не сдвигает дату.
    again = subscription(token)
    assert again["trial_ends_at"] == sub["trial_ends_at"]


def test_expired_trial_without_payment_is_free(fake_provider):
    token = "t:org-expire:owner"
    subscription(token)  # создать триал
    set_trial_end("org-expire", store_mod.to_iso(time.time() - 60))
    sub = subscription(token)
    assert sub["status"] == "expired" and sub["pro"] is False
    ent = entitlement(token)
    assert ent["plan"] == "free" and ent["status"] == "free"
    assert ent["features"] == {"projects": 1, "teo": False, "reports": False}


def test_paid_org_after_trial_is_pro(fake_provider):
    token = "t:org-after-trial:owner"
    subscription(token)
    set_trial_end("org-after-trial", store_mod.to_iso(time.time() - 60))
    assert entitlement(token)["pro"] is False
    pay(token)
    assert entitlement(token)["pro"] is True
    assert subscription(token)["status"] == "active"


# --------------------------------------------------------------------------
# Отмена / возобновление
# --------------------------------------------------------------------------

def test_cancel_keeps_rights_until_period_end(fake_provider):
    token = "t:org-cancel:owner"
    order = pay(token)
    until = subscription(token)["until"]
    response = client.post("/payments/subscription/cancel", json={}, headers=auth(token))
    assert response.status_code == 200, response.text
    body = response.json()
    assert body["cancel_at_period_end"] is True
    assert body["until"] == until
    assert body["status"] == "active"
    assert entitlement(token)["pro"] is True
    assert client.get(f"/payments/orders/{order['order_id']}",
                      headers=auth(token)).json()["status"] == "paid"


def test_resume_re_enables_renewal(fake_provider):
    token = "t:org-resume:owner"
    pay(token)
    client.post("/payments/subscription/cancel", json={}, headers=auth(token))
    response = client.post("/payments/subscription/resume", json={}, headers=auth(token))
    assert response.status_code == 200, response.text
    assert response.json()["cancel_at_period_end"] is False


def test_cancel_allowed_for_member(fake_provider):
    """Отмена — любой участник организации (System Design §12.3)."""
    pay("t:org-member-cancel:owner")
    response = client.post("/payments/subscription/cancel", json={},
                           headers=auth("t:org-member-cancel:member"))
    assert response.status_code == 200
    assert response.json()["cancel_at_period_end"] is True


# --------------------------------------------------------------------------
# Возврат
# --------------------------------------------------------------------------

def test_refund_by_owner_revokes_pro(fake_provider):
    token = "t:org-refund:owner"
    order = pay(token)
    response = client.post("/payments/subscription/refund",
                           json={"order_id": order["order_id"]}, headers=auth(token))
    assert response.status_code == 200, response.text
    body = response.json()
    assert body["status"] == "succeeded" and body["refund_id"]
    assert body["amount_rub"] == 990
    assert fake_provider.refunds[0]["payment_id"] == f"pay-{order['order_id']}"

    view = client.get(f"/payments/orders/{order['order_id']}", headers=auth(token)).json()
    assert view["status"] == "refunded" and view["refunded_at"]
    sub = subscription(token)
    assert sub["status"] == "canceled" and sub["pro"] is False
    assert entitlement(token)["status"] == "free"


def test_refund_requires_admin_role(fake_provider):
    order = pay("t:org-refund-role:owner")
    response = client.post("/payments/refunds", json={"order_id": order["order_id"]},
                           headers=auth("t:org-refund-role:member"))
    assert response.status_code == 403


def test_refund_pending_applies_on_webhook(fake_provider):
    token = "t:org-refund-pending:owner"
    order = pay(token)
    fake_provider.refund_status = "pending"
    response = client.post("/payments/refunds", json={"order_id": order["order_id"]},
                           headers=auth(token))
    assert response.status_code == 200, response.text
    assert response.json()["status"] == "pending"
    assert entitlement(token)["pro"] is True  # права ждут подтверждения

    refund_id = f"refund-pay-{order['order_id']}"
    assert post_webhook(refund_event(refund_id, f"pay-{order['order_id']}")).status_code == 200
    assert entitlement(token)["status"] == "free"
    assert subscription(token)["status"] == "canceled"

    # Повторный вебхук возврата ничего не меняет (идемпотентность по refund_id).
    assert post_webhook(refund_event(refund_id, f"pay-{order['order_id']}")
                        ).json().get("already") is True


def test_refund_without_payments_conflict(fake_provider):
    response = client.post("/payments/refunds", json={},
                           headers=auth("t:org-refund-empty:owner"))
    assert response.status_code == 409


# --------------------------------------------------------------------------
# Изоляция тенантов и организации
# --------------------------------------------------------------------------

def test_tenant_isolation_for_orders(fake_provider):
    order = checkout("t:org-iso-a:owner")
    response = client.get(f"/payments/orders/{order['order_id']}",
                          headers=auth("t:org-iso-b:owner"))
    assert response.status_code == 404


def test_foreign_org_id_forbidden(fake_provider):
    response = client.get("/payments/subscription", headers=auth("t:org-iso-c:owner"),
                          params={"org_id": "org-iso-d"})
    assert response.status_code == 403


def test_user_without_org_conflict(fake_provider):
    response = client.get("/payments/subscription", headers=auth("t:noorg:member"))
    assert response.status_code == 409


def test_org_selection_for_multi_org_user(fake_provider):
    token = "t:org-multi-1|org-multi-2:owner"
    pay(token, "month", org_id="org-multi-2")
    assert subscription(token, org_id="org-multi-2")["status"] == "active"
    assert subscription(token, org_id="org-multi-1")["status"] == "trialing"
    assert entitlement(token, org_id="org-multi-1")["trial_active"] is True


def test_transactions_visible_only_for_own_org(fake_provider):
    token = "t:org-tx:owner"
    order = pay(token)
    items = client.get("/payments/transactions", headers=auth(token)).json()["items"]
    assert len(items) == 1
    assert items[0]["event_type"] == "payment.succeeded"
    assert items[0]["status"] == "succeeded"
    assert items[0]["order_id"] == order["order_id"]
    assert "raw_payload" not in items[0]

    empty = client.get("/payments/transactions",
                       headers=auth("t:org-tx-other:owner")).json()["items"]
    assert empty == []


def test_transactions_amount_alias_matches_amount_rub(fake_provider):
    """Столбец-алиас `amount` (task-spec) синхронизирован с `amount_rub` (SD)."""
    order = pay("t:org-alias-col:owner", "year")
    with STORE.db.read() as conn:
        row = conn.query_one("SELECT amount, amount_rub, created_at, received_at "
                             "FROM transactions WHERE order_id = ?",
                             (order["order_id"],))
    assert row["amount"] == row["amount_rub"] == 9900
    assert row["created_at"] == row["received_at"]


def test_entitlement_alias_endpoint(fake_provider):
    token = "t:org-ent-alias:owner"
    direct = entitlement(token)
    alias = client.get("/entitlement", headers=auth(token))
    assert alias.status_code == 200
    assert alias.json()["org_id"] == direct["org_id"]
    assert alias.json()["plan"] == direct["plan"]


def test_revoked_token_rejected(monkeypatch, fake_provider):
    def denied(token):
        raise HTTPException(status_code=401, detail="сессия не найдена")

    monkeypatch.setattr(pm, "verify_token", denied)
    response = client.post("/payments/checkout", json={"plan": "month"},
                           headers=auth("t:org-revoked:owner"))
    assert response.status_code == 401
