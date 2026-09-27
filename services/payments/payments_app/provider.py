# -*- coding: utf-8 -*-
"""Платёжный провайдер: интерфейс `PaymentProvider` и реализация ЮKassa (ADR-3).

Основание: System Design v1 ADR-3 («Платёжный провайдер: ЮKassa + схема
webhook/entitlement»), §4 (безопасность) и §12.3 (контракт /payments).

Принципы:
  * Провайдер изолирован за интерфейсом (`create_payment`, `process_webhook`,
    `refund`, `get_subscription`, `cancel_subscription`), чтобы Stripe/
    CloudPayments оставались запасным вариантом без правки бизнес-логики.
  * ЮKassa вызывается напрямую по HTTPS (`urllib.request`, stdlib) — без SDK;
    аутентификация Basic (shopId:secretKey), идемпотентность через
    заголовок `Idempotence-Key`.
  * Вебхук верифицируется HMAC-SHA256 по СЫРОМУ телу запроса
    (`YUKASSA_WEBHOOK_SECRET`); пустой секрет = вебхук отклоняется (fail closed),
    никаких dev-подтверждений на стороне сервиса.
  * Секреты никогда не попадают в ответы API и не логируются.

Соответствие объектов: у ЮKassa нет отдельной сущности «заказ» — заказом
считается платёж (`payment.id`), поэтому `provider_order_id == provider_payment_id`
для событий `payment.*`; для событий `refund.*` `provider_payment_id` — id
возврата, а `payment_id`/`provider_order_id` — id исходного платежа.
"""
from __future__ import annotations

import base64
import hashlib
import hmac
import json
import urllib.error
import urllib.request
import uuid
from typing import Any, Dict, Mapping, Optional

from . import config
from .store import BillingStore


class ProviderError(RuntimeError):
    """Ошибка провайдера (апстрим/конфигурация)."""


class ProviderNotConfigured(ProviderError):
    """ЮKassa не настроена (нет YUKASSA_SHOP_ID/YUKASSA_SECRET_KEY)."""


class WebhookSignatureError(ProviderError):
    """Подпись вебхука отсутствует/не совпадает."""


class WebhookPayloadError(ProviderError):
    """Тело вебхука не является корректным JSON-уведомлением ЮKassa."""


# Заголовки, в которых может прийти подпись (разные версии/конфигурации).
SIGNATURE_HEADERS = (
    "x-signature",
    "x-content-signature",
    "content-signature",
    "x-webhook-signature",
    "x-yookassa-signature",
    "x-hmac-sha256",
)


# --------------------------------------------------------------------------
# Подпись вебхука
# --------------------------------------------------------------------------

def compute_signature(secret: str, raw_body: bytes) -> str:
    """HMAC-SHA256 (hex) от сырого тела запроса."""
    return hmac.new(secret.encode("utf-8"), raw_body, hashlib.sha256).hexdigest()


def extract_signature(headers: Mapping[str, str]) -> Optional[str]:
    lowered = {str(k).lower(): v for k, v in (headers or {}).items()}
    for name in SIGNATURE_HEADERS:
        value = lowered.get(name)
        if value:
            return str(value).strip()
    return None


def _strip_algorithm(value: str) -> str:
    text = value.strip()
    for prefix in ("sha256=", "hmac-sha256=", "hmac="):
        if text.lower().startswith(prefix):
            return text[len(prefix):].strip()
    return text


def verify_webhook_signature(raw_body: bytes, headers: Mapping[str, str],
                             secret: str) -> None:
    """Проверка HMAC-SHA256 подписи вебхука (constant-time).

    Пустой секрет → 503 (fail closed): без настроенного `YUKASSA_WEBHOOK_SECRET`
    сервис не принимает уведомления и не подменяет проверку «тестовым» режимом.
    """
    if not secret:
        raise ProviderNotConfigured(
            "Вебхук не настроен: задайте YUKASSA_WEBHOOK_SECRET")
    provided = extract_signature(headers)
    if not provided:
        raise WebhookSignatureError("В вебхуке нет подписи (HMAC-SHA256)")
    expected = compute_signature(secret, raw_body)
    if not hmac.compare_digest(_strip_algorithm(provided).lower(), expected.lower()):
        raise WebhookSignatureError("Подпись вебхука не совпадает")


# --------------------------------------------------------------------------
# Разбор уведомления
# --------------------------------------------------------------------------

def rub_amount(value: Any) -> int:
    """«5000.00» → 5000 ₽ (в billing деньги хранятся целыми рублями)."""
    if value is None or value == "":
        return 0
    try:
        return int(round(float(str(value).replace(",", "."))))
    except (TypeError, ValueError):
        raise WebhookPayloadError(f"Некорректная сумма в уведомлении: {value!r}")


def normalize_event(payload: Dict[str, Any]) -> Dict[str, Any]:
    """Уведомление ЮKassa → внутреннее событие billing."""
    event = str(payload.get("event") or "").strip()
    obj = payload.get("object") or {}
    if not event or not isinstance(obj, dict):
        raise WebhookPayloadError("Уведомление без event/object")
    kind = event.split(".", 1)[0]
    amount = obj.get("amount") or {}
    metadata = obj.get("metadata") or {}
    method = obj.get("payment_method") or {}
    event_out: Dict[str, Any] = {
        "event": event,
        "kind": kind,
        "status": obj.get("status") or "",
        "paid": bool(obj.get("paid")),
        "amount_rub": rub_amount(amount.get("value")),
        "currency": amount.get("currency") or "RUB",
        "order_id": metadata.get("order_id"),
        "org_id": metadata.get("org_id"),
        "plan": metadata.get("plan"),
        "payment_method_id": method.get("id"),
        "saved_payment_method": bool(method.get("saved")),
        "raw": payload,
    }
    if kind == "refund":
        event_out["provider_payment_id"] = obj.get("id")
        event_out["payment_id"] = obj.get("payment_id")
        event_out["provider_order_id"] = obj.get("payment_id")
    else:
        event_out["provider_payment_id"] = obj.get("id")
        event_out["provider_order_id"] = obj.get("id")
    if not event_out["provider_payment_id"]:
        raise WebhookPayloadError("Уведомление без id объекта")
    return event_out


# --------------------------------------------------------------------------
# Интерфейс провайдера
# --------------------------------------------------------------------------

class PaymentProvider:
    """Интерфейс платёжного провайдера (checkout/webhook/refund/подписка)."""

    name = "abstract"

    def __init__(self, store: BillingStore) -> None:
        self.store = store

    # -- checkout ---------------------------------------------------------
    def create_payment(self, order: Dict[str, Any], plan: Dict[str, Any],
                       return_url: str = "",
                       customer_email: Optional[str] = None) -> Dict[str, Any]:
        """Создать платёж у провайдера → {provider_payment_id, confirmation_url}."""
        raise NotImplementedError

    # -- вебхук -----------------------------------------------------------
    def process_webhook(self, raw_body: bytes,
                        headers: Mapping[str, str]) -> Dict[str, Any]:
        """Проверить подпись и нормализовать уведомление провайдера."""
        raise NotImplementedError

    # -- возврат ----------------------------------------------------------
    def refund(self, payment_id: str, amount_rub: int, order_id: str = "",
               idempotence_key: str = "") -> Dict[str, Any]:
        """Возврат через провайдера → {refund_id, status}."""
        raise NotImplementedError

    # -- подписка ---------------------------------------------------------
    # Источник истины по подписке — наша БД (журнал events + entitlement),
    # поэтому реализация по умолчанию читает/меняет её; провайдер может
    # дополнять ответ (например, признаками автоплатежей ЮKassa).
    def get_subscription(self, org_id: str) -> Dict[str, Any]:
        """Состояние подписки организации (наша БД — источник истины)."""
        view = self.store.subscription_view(org_id)
        view["provider"] = self.name
        return view

    def cancel_subscription(self, org_id: str) -> Dict[str, Any]:
        """Отключить автопродление: cancel_at_period_end = true."""
        view = self.store.set_cancel_at_period_end(org_id, True)
        view["provider"] = self.name
        return view

    # -- прочее -----------------------------------------------------------
    def describe(self) -> Dict[str, Any]:
        return {"provider": self.name}


# --------------------------------------------------------------------------
# ЮKassa
# --------------------------------------------------------------------------

class YooKassaProvider(PaymentProvider):
    """ЮKassa: POST /payments, POST /refunds, вебхуки с HMAC-подписью."""

    name = "yookassa"

    def __init__(self, store: BillingStore, shop_id: str = "", secret_key: str = "",
                 webhook_secret: str = "", api_url: str = "",
                 save_payment_method: bool = False) -> None:
        super().__init__(store)
        self.shop_id = (shop_id or "").strip()
        self.secret_key = (secret_key or "").strip()
        self.webhook_secret = (webhook_secret or "").strip()
        self.api_url = (api_url or config.YUKASSA_API_URL).rstrip("/")
        self.save_payment_method = bool(save_payment_method)

    # -- служебное --------------------------------------------------------
    @property
    def configured(self) -> bool:
        return bool(self.shop_id and self.secret_key)

    def _auth_header(self) -> str:
        raw = f"{self.shop_id}:{self.secret_key}".encode("utf-8")
        return "Basic " + base64.b64encode(raw).decode("ascii")

    def _request(self, method: str, path: str, payload: Dict[str, Any],
                 idempotence_key: str = "") -> Dict[str, Any]:
        if not self.configured:
            raise ProviderNotConfigured(
                "ЮKassa не настроена: задайте YUKASSA_SHOP_ID и YUKASSA_SECRET_KEY")
        url = f"{self.api_url}{path}"
        data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        headers = {
            "Authorization": self._auth_header(),
            "Content-Type": "application/json",
            "Accept": "application/json",
            "User-Agent": "prepress-planer-billing/1.0",
        }
        if idempotence_key:
            headers["Idempotence-Key"] = str(idempotence_key)
        req = urllib.request.Request(url, data=data, headers=headers, method=method)
        try:
            with urllib.request.urlopen(req, timeout=20) as resp:
                body = resp.read().decode("utf-8", errors="replace")
        except urllib.error.HTTPError as exc:
            detail = exc.read().decode("utf-8", errors="replace")[:300]
            raise ProviderError(
                f"ЮKassa вернула ошибку {exc.code}: {detail}") from exc
        except (urllib.error.URLError, TimeoutError, OSError) as exc:
            raise ProviderError(f"ЮKassa недоступна: {exc}") from exc
        try:
            parsed = json.loads(body)
        except ValueError as exc:
            raise ProviderError("ЮKassa вернула некорректный JSON") from exc
        if not isinstance(parsed, dict):
            raise ProviderError("ЮKassa вернула неожиданный ответ")
        return parsed

    # -- checkout ---------------------------------------------------------
    def create_payment(self, order: Dict[str, Any], plan: Dict[str, Any],
                       return_url: str = "",
                       customer_email: Optional[str] = None) -> Dict[str, Any]:
        amount = {"value": f"{int(order['amount_rub'])}.00",
                  "currency": plan.get("currency") or "RUB"}
        confirmation: Dict[str, Any] = {"type": "redirect"}
        if return_url:
            confirmation["return_url"] = return_url
        payload: Dict[str, Any] = {
            "amount": amount,
            "capture": True,
            "confirmation": confirmation,
            "description": f"Препресс-Планер: {plan['title']}"[:128],
            "metadata": {
                "order_id": order["id"],
                "org_id": order["org_id"],
                "user_id": order["user_id"],
                "plan": order["plan"],
            },
        }
        if self.save_payment_method:
            # Автоплатежи ЮKassa включаются только после активации у мерчанта.
            payload["save_payment_method"] = True
        if config.RECEIPT_ENABLED:
            # Чек — объект внутри тела создания платежа (ЮKassa API v3, ADR-3).
            receipt: Dict[str, Any] = {
                "items": [{
                    "description": (f"Подписка {plan.get('title') or plan.get('plan')} "
                                    "— Препресс-Планер")[:128],
                    "quantity": "1",
                    "amount": {"value": f"{int(order['amount_rub']):.2f}",
                               "currency": amount["currency"]},
                    "vat_code": int(config.RECEIPT_VAT_CODE),
                    "payment_subject": "service",
                    "payment_mode": "full_payment",
                }],
            }
            email = (customer_email or "").strip()
            if email:
                receipt["customer"] = {"email": email}
            payload["receipt"] = receipt
        data = self._request("POST", "/payments", payload,
                             idempotence_key=order["id"])
        payment_id = str(data.get("id") or "")
        if not payment_id:
            raise ProviderError("ЮKassa не вернула id платежа")
        conf = data.get("confirmation") or {}
        return {
            "provider_payment_id": payment_id,
            "provider_order_id": payment_id,  # у ЮKassa заказ = платёж
            "status": data.get("status") or "pending",
            "confirmation_url": conf.get("confirmation_url") or "",
            "raw": data,
        }

    # -- вебхук -----------------------------------------------------------
    def process_webhook(self, raw_body: bytes,
                        headers: Mapping[str, str]) -> Dict[str, Any]:
        verify_webhook_signature(raw_body, headers, self.webhook_secret)
        try:
            payload = json.loads(raw_body.decode("utf-8"))
        except (ValueError, UnicodeDecodeError) as exc:
            raise WebhookPayloadError("Тело вебхука не является JSON") from exc
        if not isinstance(payload, dict):
            raise WebhookPayloadError("Тело вебхука должно быть объектом JSON")
        return normalize_event(payload)

    # -- возврат ----------------------------------------------------------
    def refund(self, payment_id: str, amount_rub: int, order_id: str = "",
               idempotence_key: str = "") -> Dict[str, Any]:
        if not payment_id:
            raise ProviderError("Не указан id платежа для возврата")
        payload: Dict[str, Any] = {
            "payment_id": payment_id,
            "amount": {"value": f"{int(amount_rub)}.00", "currency": "RUB"},
        }
        if order_id:
            payload["description"] = f"Возврат по заказу {order_id}"[:128]
        data = self._request("POST", "/refunds", payload,
                             idempotence_key=idempotence_key or uuid.uuid4().hex)
        refund_id = str(data.get("id") or "")
        if not refund_id:
            raise ProviderError("ЮKassa не вернула id возврата")
        return {"refund_id": refund_id, "status": data.get("status") or "pending",
                "raw": data}

    # -- подписка ---------------------------------------------------------
    def get_subscription(self, org_id: str) -> Dict[str, Any]:
        view = super().get_subscription(org_id)
        view["provider_configured"] = self.configured
        return view

    def cancel_subscription(self, org_id: str) -> Dict[str, Any]:
        # У ЮKassa нет объекта «подписка»: прекращаем автопродление у себя
        # (cancel_at_period_end) — при отключённых автоплатежах новых списаний нет.
        view = super().cancel_subscription(org_id)
        view["provider_configured"] = self.configured
        return view

    def describe(self) -> Dict[str, Any]:
        return {
            "provider": self.name,
            "configured": self.configured,
            "api_url": self.api_url,
            "webhook_signature": bool(self.webhook_secret),
            "save_payment_method": self.save_payment_method,
        }


class UnconfiguredProvider(PaymentProvider):
    """ЮKassa не настроена (нет ключей в среде).

    Сервис читает подписку/entitlement из своей БД, но НЕ создаёт платежи и не
    принимает вебхуки без секрета: никаких «тестовых подтверждений» (ADR-3).
    """

    name = "yookassa-unconfigured"

    def __init__(self, store: BillingStore, webhook_secret: str = "") -> None:
        super().__init__(store)
        self.webhook_secret = (webhook_secret or "").strip()

    _MESSAGE = ("ЮKassa не настроена: задайте YUKASSA_SHOP_ID и "
                "YUKASSA_SECRET_KEY (секреты — только через env/секрет-менеджер)")

    def create_payment(self, order: Dict[str, Any], plan: Dict[str, Any],
                       return_url: str = "",
                       customer_email: Optional[str] = None) -> Dict[str, Any]:
        raise ProviderNotConfigured(self._MESSAGE)

    def refund(self, payment_id: str, amount_rub: int, order_id: str = "",
               idempotence_key: str = "") -> Dict[str, Any]:
        raise ProviderNotConfigured(self._MESSAGE)

    def process_webhook(self, raw_body: bytes,
                        headers: Mapping[str, str]) -> Dict[str, Any]:
        verify_webhook_signature(raw_body, headers, self.webhook_secret)
        try:
            payload = json.loads(raw_body.decode("utf-8"))
        except (ValueError, UnicodeDecodeError) as exc:
            raise WebhookPayloadError("Тело вебхука не является JSON") from exc
        return normalize_event(payload)

    def get_subscription(self, org_id: str) -> Dict[str, Any]:
        view = super().get_subscription(org_id)
        view["provider_configured"] = False
        return view

    def cancel_subscription(self, org_id: str) -> Dict[str, Any]:
        view = super().cancel_subscription(org_id)
        view["provider_configured"] = False
        return view

    def describe(self) -> Dict[str, Any]:
        return {"provider": self.name, "configured": False,
                "webhook_signature": bool(self.webhook_secret)}


def build_provider(store: BillingStore) -> PaymentProvider:
    """Провайдер по конфигурации среды (ЮKassa либо «не настроена»)."""
    if config.YUKASSA_CONFIGURED:
        return YooKassaProvider(
            store,
            shop_id=config.YUKASSA_SHOP_ID,
            secret_key=config.YUKASSA_SECRET_KEY,
            webhook_secret=config.YUKASSA_WEBHOOK_SECRET,
            api_url=config.YUKASSA_API_URL,
            save_payment_method=config.SAVE_PAYMENT_METHOD,
        )
    return UnconfiguredProvider(store, webhook_secret=config.YUKASSA_WEBHOOK_SECRET)
