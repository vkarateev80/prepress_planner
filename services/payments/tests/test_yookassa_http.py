# -*- coding: utf-8 -*-
"""Тесты реального HTTP-канала ЮKassa (без внешней сети).

Проверяется продакшн-реализация `YooKassaProvider` на локальном заглушечном
HTTP-сервере: Basic-аутентификация (shopId:secretKey), заголовок
`Idempotence-Key`, тело запроса (`amount`, `confirmation.return_url`, `metadata`,
`receipt`, `save_payment_method`), разбор `confirmation_url` и возврата, а также
обработка ошибок апстрима.

Секреты в тестах — фиктивные; проверяется только формат заголовков.
"""
import base64
import json
import os
import sys
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from typing import Any, Dict, List

import pytest

os.environ.setdefault("PP_DATA_DIR", tempfile.mkdtemp(prefix="pp_yk_test_"))
os.environ.setdefault("PP_AUTH_URL", "http://auth.test:8121")

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from payments_app import config  # noqa: E402
from payments_app.db import Database  # noqa: E402
from payments_app.provider import (ProviderError, ProviderNotConfigured,  # noqa: E402
                                   UnconfiguredProvider, WebhookSignatureError,
                                   YooKassaProvider, build_provider,
                                   compute_signature, extract_signature,
                                   normalize_event, verify_webhook_signature)
from payments_app.store import BillingStore  # noqa: E402

SHOP_ID = "test_shop"
SECRET_KEY = "test_secret_key"


class _StubHandler(BaseHTTPRequestHandler):
    """Заглушка API ЮKassa: записывает запросы, отдаёт заданные ответы."""

    requests: List[Dict[str, Any]] = []
    responses: List[Any] = []

    def do_POST(self) -> None:  # noqa: N802 (интерфейс BaseHTTPRequestHandler)
        self._handle("POST")

    def do_GET(self) -> None:  # noqa: N802 (сверка объектов вебхука)
        self._handle("GET")

    def _handle(self, method: str) -> None:
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length).decode("utf-8") if length else ""
        type(self).requests.append({
            "path": self.path,
            "method": method,
            "authorization": self.headers.get("Authorization"),
            "idempotence_key": self.headers.get("Idempotence-Key"),
            "content_type": self.headers.get("Content-Type"),
            "body": json.loads(raw or "{}"),
        })
        status, payload = type(self).responses.pop(0)
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):  # тишина в выводе тестов
        return


@pytest.fixture()
def api():
    _StubHandler.requests = []
    _StubHandler.responses = []
    server = HTTPServer(("127.0.0.1", 0), _StubHandler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    yield f"http://127.0.0.1:{server.server_port}"
    server.shutdown()
    server.server_close()


@pytest.fixture()
def store():
    data_dir = tempfile.mkdtemp(prefix="pp_yk_db_")
    db = Database(db_url="", data_dir=data_dir)
    billing = BillingStore(db)
    billing.init()
    return billing


ORDER = {
    "id": "order-1",
    "org_id": "org-1",
    "user_id": "user-1",
    "plan": "month",
    "amount_rub": 990,
    "currency": "RUB",
}

PLAN = {"plan": "month", "title": "Pro на месяц", "amount_rub": 990,
        "days": 30, "currency": "RUB"}


def test_create_payment_uses_basic_auth_and_idempotence_key(api, store):
    _StubHandler.responses = [(200, {
        "id": "2f8f0e1e-0001-0000-0000-000000000001",
        "status": "pending",
        "confirmation": {"type": "redirect",
                         "confirmation_url": "https://yoomoney.ru/checkout/x"},
    })]
    provider = YooKassaProvider(store, shop_id=SHOP_ID, secret_key=SECRET_KEY,
                                webhook_secret="whsec", api_url=api)
    result = provider.create_payment(ORDER, PLAN, return_url="https://pp.example/billing/return?order_id=order-1")

    assert result["provider_payment_id"] == "2f8f0e1e-0001-0000-0000-000000000001"
    assert result["confirmation_url"] == "https://yoomoney.ru/checkout/x"
    assert result["provider_order_id"] == result["provider_payment_id"]

    sent = _StubHandler.requests[0]
    assert sent["path"].endswith("/payments")
    expected_auth = base64.b64encode(f"{SHOP_ID}:{SECRET_KEY}".encode()).decode()
    assert sent["authorization"] == f"Basic {expected_auth}"
    assert sent["idempotence_key"] == "order-1"  # ретрай checkout идемпотентен
    assert sent["body"]["amount"] == {"value": "990.00", "currency": "RUB"}
    assert sent["body"]["capture"] is True
    assert sent["body"]["confirmation"]["type"] == "redirect"
    assert "order-1" in sent["body"]["confirmation"]["return_url"]
    assert sent["body"]["metadata"] == {"order_id": "order-1", "org_id": "org-1",
                                        "user_id": "user-1", "plan": "month"}


def test_create_payment_without_keys_raises(store):
    provider = YooKassaProvider(store, shop_id="", secret_key="", api_url="http://127.0.0.1:1")
    with pytest.raises(ProviderError) as exc:
        provider.create_payment(ORDER, PLAN)
    assert "ЮKassa не настроена" in str(exc.value)


def test_create_payment_upstream_error_is_wrapped(api, store):
    _StubHandler.responses = [(400, {"type": "error", "code": "invalid_request",
                                     "description": "Amount is too small"})]
    provider = YooKassaProvider(store, shop_id=SHOP_ID, secret_key=SECRET_KEY,
                                webhook_secret="whsec", api_url=api)
    with pytest.raises(ProviderError) as exc:
        provider.create_payment(ORDER, PLAN)
    assert "400" in str(exc.value) and "invalid_request" in str(exc.value)


def _pending_response(payment_id: str = "2f8f0e1e-0001-0000-0000-000000000001"):
    """Успешный ответ POST /payments для заглушки ЮKassa."""
    return (200, {
        "id": payment_id,
        "status": "pending",
        "confirmation": {"type": "redirect",
                         "confirmation_url": "https://yoomoney.ru/checkout/x"},
    })


def _provider(api, store) -> YooKassaProvider:
    return YooKassaProvider(store, shop_id=SHOP_ID, secret_key=SECRET_KEY,
                            webhook_secret="whsec", api_url=api)


def test_create_payment_receipt_with_customer_email(api, store):
    _StubHandler.responses = [_pending_response()]
    provider = _provider(api, store)
    provider.create_payment(ORDER, PLAN, customer_email="user@example.com")

    receipt = _StubHandler.requests[0]["body"]["receipt"]
    assert receipt["customer"] == {"email": "user@example.com"}
    item = receipt["items"][0]
    assert item["vat_code"] == 1  # YUKASSA_RECEIPT_VAT_CODE по умолчанию «1»
    assert item["quantity"] == "1"
    assert item["amount"] == {"value": "990.00", "currency": "RUB"}  # сумма заказа
    assert item["payment_subject"] == "service"
    assert item["payment_mode"] == "full_payment"
    assert item["description"].startswith("Подписка ")
    assert "Препресс-Планер" in item["description"]
    assert len(item["description"]) <= 128  # ограничение ЮKassa на описание


def test_create_payment_receipt_without_email_omits_customer(api, store):
    _StubHandler.responses = [_pending_response()]
    provider = _provider(api, store)
    provider.create_payment(ORDER, PLAN)

    receipt = _StubHandler.requests[0]["body"]["receipt"]
    assert "customer" not in receipt  # email не передан — блока customer нет
    assert receipt["items"], "items обязаны быть и без customer"


def test_create_payment_receipt_disabled(api, store, monkeypatch):
    monkeypatch.setenv("YUKASSA_RECEIPT_ENABLED", "0")
    # config читает env на импорте, поэтому на время теста правим кэш конфига.
    monkeypatch.setattr(config, "RECEIPT_ENABLED", False)
    _StubHandler.responses = [_pending_response()]
    provider = _provider(api, store)
    provider.create_payment(ORDER, PLAN, customer_email="user@example.com")

    assert "receipt" not in _StubHandler.requests[0]["body"]


def test_create_payment_receipt_vat_code_from_env(api, store, monkeypatch):
    monkeypatch.setenv("YUKASSA_RECEIPT_VAT_CODE", "2")
    monkeypatch.setattr(config, "RECEIPT_VAT_CODE", "2")
    _StubHandler.responses = [_pending_response()]
    provider = _provider(api, store)
    provider.create_payment(ORDER, PLAN)

    assert _StubHandler.requests[0]["body"]["receipt"]["items"][0]["vat_code"] == 2


def test_save_payment_method_env_sets_payload_flag(api, store, monkeypatch):
    """YUKASSA_SAVE_PAYMENT_METHOD=1 → save_payment_method: true в payload."""
    monkeypatch.setenv("YUKASSA_SAVE_PAYMENT_METHOD", "1")
    # config читает env на импорте, поэтому на время теста правим кэш конфига;
    # build_provider собирает провайдер из config — как в проде.
    monkeypatch.setattr(config, "SAVE_PAYMENT_METHOD", True)
    monkeypatch.setattr(config, "YUKASSA_SHOP_ID", SHOP_ID)
    monkeypatch.setattr(config, "YUKASSA_SECRET_KEY", SECRET_KEY)
    monkeypatch.setattr(config, "YUKASSA_WEBHOOK_SECRET", "whsec")
    monkeypatch.setattr(config, "YUKASSA_API_URL", api)
    monkeypatch.setattr(config, "YUKASSA_CONFIGURED", True)
    _StubHandler.responses = [_pending_response()]
    provider = build_provider(store)
    provider.create_payment(ORDER, PLAN)

    assert _StubHandler.requests[0]["body"]["save_payment_method"] is True


def test_unconfigured_provider_accepts_customer_email_kwarg(store):
    """Сигнатура совместима: email не ломает заглушку без ключей."""
    provider = UnconfiguredProvider(store)
    with pytest.raises(ProviderNotConfigured):
        provider.create_payment(ORDER, PLAN, customer_email="user@example.com")


def test_refund_posts_to_refunds_endpoint(api, store):
    _StubHandler.responses = [(200, {"id": "refund-1", "status": "succeeded",
                                     "amount": {"value": "990.00", "currency": "RUB"}})]
    provider = YooKassaProvider(store, shop_id=SHOP_ID, secret_key=SECRET_KEY,
                                webhook_secret="whsec", api_url=api)
    result = provider.refund("pay-1", 990, order_id="order-1",
                             idempotence_key="order-1")
    assert result == {"refund_id": "refund-1", "status": "succeeded",
                      "raw": {"id": "refund-1", "status": "succeeded",
                              "amount": {"value": "990.00", "currency": "RUB"}}}
    sent = _StubHandler.requests[0]
    assert sent["path"].endswith("/refunds")
    assert sent["body"]["payment_id"] == "pay-1"
    assert sent["body"]["amount"] == {"value": "990.00", "currency": "RUB"}
    assert sent["idempotence_key"] == "order-1"


def test_webhook_signature_variants(store):
    body = json.dumps({"event": "payment.succeeded",
                       "object": {"id": "pay-1", "amount": {"value": "990.00"},
                                  "metadata": {"order_id": "order-1"}}}).encode()
    good = compute_signature("whsec", body)

    for header in ("X-Signature", "Content-Signature", "X-Webhook-Signature"):
        verify_webhook_signature(body, {header: good}, "whsec")
    verify_webhook_signature(body, {"X-Signature": f"sha256={good}"}, "whsec")
    # Регистр значения не важен, а подделка отклоняется.
    verify_webhook_signature(body, {"X-Signature": good.upper()}, "whsec")
    with pytest.raises(WebhookSignatureError):
        verify_webhook_signature(body, {"X-Signature": compute_signature("other", body)},
                                 "whsec")
    with pytest.raises(WebhookSignatureError):
        verify_webhook_signature(body, {}, "whsec")
    assert extract_signature({"X-Signature": "abc"}) == "abc"


def test_webhook_without_secret_is_rejected(store):
    body = b'{"event":"payment.succeeded","object":{"id":"pay-1"}}'
    provider = YooKassaProvider(store, shop_id=SHOP_ID, secret_key=SECRET_KEY,
                                webhook_secret="")
    with pytest.raises(ProviderError) as exc:
        provider.process_webhook(body, {"X-Signature": "deadbeef"})
    assert "YUKASSA_WEBHOOK_SECRET" in str(exc.value)


def test_process_webhook_normalizes_payment_and_refund(api, store):
    """Вебхук: подпись (если есть) → GET объекта у «ЮKassa» → нормализация.

    Данные события берутся из ответа GET, а не из тела уведомления.
    """
    secret = "whsec"
    provider = YooKassaProvider(store, shop_id=SHOP_ID, secret_key=SECRET_KEY,
                                webhook_secret=secret, api_url=api)
    _StubHandler.responses = [(200, {
        "id": "pay-9", "status": "succeeded", "paid": True,
        "amount": {"value": "9900.00", "currency": "RUB"},
        "metadata": {"order_id": "order-9", "org_id": "org-9", "plan": "year"},
        "payment_method": {"id": "pm-9", "saved": True},
    })]
    payment_body = json.dumps({
        "event": "payment.succeeded",
        "object": {"id": "pay-9", "status": "succeeded"},
    }).encode()
    event = provider.process_webhook(
        payment_body, {"X-Signature": compute_signature(secret, payment_body)})
    assert event["event"] == "payment.succeeded"
    assert event["provider_payment_id"] == "pay-9"
    assert event["provider_order_id"] == "pay-9"
    assert event["amount_rub"] == 9900 and event["currency"] == "RUB"
    assert event["order_id"] == "order-9" and event["plan"] == "year"
    assert event["payment_method_id"] == "pm-9" and event["saved_payment_method"] is True
    sent = _StubHandler.requests[-1]
    assert sent["method"] == "GET" and sent["path"].endswith("/payments/pay-9")

    _StubHandler.responses = [(200, {
        "id": "refund-9", "payment_id": "pay-9", "status": "succeeded",
        "amount": {"value": "9900.00", "currency": "RUB"},
    })]
    refund_body = json.dumps({
        "event": "refund.succeeded",
        "object": {"id": "refund-9", "payment_id": "pay-9", "status": "succeeded"},
    }).encode()
    refund = provider.process_webhook(
        refund_body, {"X-Signature": compute_signature(secret, refund_body)})
    assert refund["kind"] == "refund"
    assert refund["provider_payment_id"] == "refund-9"
    assert refund["payment_id"] == "pay-9"
    assert refund["provider_order_id"] == "pay-9"
    sent = _StubHandler.requests[-1]
    assert sent["method"] == "GET" and sent["path"].endswith("/refunds/refund-9")


def test_normalize_event_rejects_garbage():
    with pytest.raises(ProviderError):
        normalize_event({"object": {"id": "x"}})
    with pytest.raises(ProviderError):
        normalize_event({"event": "payment.succeeded", "object": {"amount": {"value": "abc"}}})
