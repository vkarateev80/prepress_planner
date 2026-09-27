# -*- coding: utf-8 -*-
"""Billing-сервис «Препресс-Планер»: ЮKassa, подписка, триал, entitlement.

Основание: PRD v2 (F-20, F-21, F-22) и System Design v1 (ADR-3, §12.3, §13.2).
Заглушка (тестовый `confirm`, вебхук по `order_id`, подписка по user_id) УДАЛЕНА.

Поток:
  1) `POST /payments/checkout {plan, org_id?}` (Bearer, организация из сессии
     через `POST {PP_AUTH_URL}/auth/verify`) → заказ `pending` → платёж ЮKassa →
     клиенту возвращается `confirmation_url` (никаких платёжных секретов);
  2) пользователь платит на стороне ЮKassa → провайдер шлёт
     `POST /payments/webhook` (без Bearer, проверка HMAC-SHA256 подписи) →
     поиск заказа по `provider_order_id` → идемпотентная запись `transactions`
     (UNIQUE `provider_payment_id`) → продление `subscriptions` от конца
     текущего периода → пересчёт `entitlements`;
  3) `GET /payments/subscription` и `GET /payments/entitlement` (Bearer, org из
     сессии) — состояние подписки и права; клиент не доверяет URL оплаты;
  4) `POST /payments/subscription/cancel` → `cancel_at_period_end=true`,
     `POST /payments/subscription/resume` → снова продлевать;
  5) `POST /payments/subscription/refund` (алиас `POST /payments/refunds`,
     owner/admin) → `POST /refunds` ЮKassa → права понижаются до Free.

Триал 15 дней (`PP_TRIAL_DAYS`) ведёт этот сервис (auth/entitlement-слой), а не
провайдер: подписка создаётся `trialing` при первом обращении организации, и до
окончания триала права Pro выдаются как `trial_active=true`; после окончания без
оплаты — Free; после успешной оплаты — Pro на период тарифа.

Токены не проверяются локально: сервис вызывает auth `POST /auth/verify` и
получает `{sub, email, orgs:[{org_id, role}]}`; членство в организации и роль
проверяются на сервере (N-4). Секреты ЮKassa — только в env.

Хранилище: SQLite (`PP_DATA_DIR/payments.db`) либо PostgreSQL (`DB_URL`).

env: см. `payments_app/config.py` (PP_AUTH_URL, DB_URL, PP_DATA_DIR,
YUKASSA_SHOP_ID, YUKASSA_SECRET_KEY, YUKASSA_WEBHOOK_SECRET, YUKASSA_API_URL,
PP_TRIAL_DAYS, PP_PRO_MONTH_PRICE_RUB, PP_PRO_YEAR_PRICE_RUB, PP_PUBLIC_BASE).

Зависимости: stdlib + fastapi/pydantic (+psycopg2 для PostgreSQL). ЮKassa
вызывается напрямую через `urllib.request` — SDK не требуется.
"""
from __future__ import annotations

import json
from typing import Any, Dict, List, Optional, Tuple
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

from fastapi import Depends, FastAPI, Header, HTTPException, Query, Request as FastAPIRequest
from pydantic import BaseModel, Field

from . import config
from .db import Database
from .provider import (PaymentProvider, ProviderError, ProviderNotConfigured,
                       WebhookPayloadError, WebhookSignatureError, build_provider)
from .store import (BillingStore, OrderNotFound, StoreError, now_epoch, to_iso)

# ---------- инфраструктура ----------

DB = Database(config.DB_URL, config.DATA_DIR)
STORE = BillingStore(DB)
PROVIDER: PaymentProvider = build_provider(STORE)

_SCHEMA: Dict[str, Any] = {"ok": False, "info": None, "error": None}


def log_event(name: str, **fields: Any) -> None:
    """Структурированный лог (System Design §6): org/user/order/refund id."""
    payload: Dict[str, Any] = {"ts": to_iso(now_epoch()), "service": config.SERVICE_NAME,
                               "event": name}
    payload.update({k: v for k, v in fields.items() if v is not None})
    print(json.dumps(payload, ensure_ascii=False, default=str), flush=True)


def ensure_schema() -> Dict[str, Any]:
    """Инициализация схемы (с повтором после старта, если БД была недоступна)."""
    if _SCHEMA["ok"]:
        return _SCHEMA["info"]
    try:
        info = STORE.init()
    except Exception as exc:  # noqa: BLE001 — сообщение уходит в /healthz и 503
        _SCHEMA.update(ok=False, info=None, error=str(exc))
        raise HTTPException(status_code=503,
                            detail=f"База данных недоступна: {exc}")
    _SCHEMA.update(ok=True, info=info, error=None)
    if info.get("renamed_legacy"):
        log_event("db_migrated_legacy", renamed=info["renamed_legacy"])
    return info


def get_provider() -> PaymentProvider:
    """Провайдер (в тестах подменяется через app.dependency_overrides)."""
    return PROVIDER


def db_ready() -> None:
    ensure_schema()


# ---------- проверка токена через auth ----------

def verify_token(token: str) -> Dict[str, Any]:
    """`POST {PP_AUTH_URL}/auth/verify`: токен → {sub, email, orgs}.

    Токен проверяется в auth (серверные сессии, отзыв), поэтому payments видит
    отозванную сессию сразу. В тестах функция подменяется фейком.
    """
    req = Request(
        f"{config.AUTH_URL}/auth/verify",
        data=b"",
        headers={"Authorization": f"Bearer {token}"},
        method="POST",
    )
    try:
        with urlopen(req, timeout=8) as resp:
            body = json.loads(resp.read().decode("utf-8"))
    except HTTPError as exc:
        detail = exc.read().decode("utf-8", errors="replace")
        raise HTTPException(status_code=401,
                            detail=f"Недействительный токен: {detail[:200]}")
    except (URLError, TimeoutError, OSError) as exc:
        raise HTTPException(status_code=503,
                            detail=f"Сервис авторизации недоступен: {exc}")
    return {
        "sub": body.get("sub"),
        "email": body.get("email"),
        "orgs": body.get("orgs") or [],
    }


def auth_dep(authorization: Optional[str] = Header(default=None)) -> Dict[str, Any]:
    if not authorization or not authorization.startswith("Bearer "):
        raise HTTPException(status_code=401, detail="Требуется токен")
    return verify_token(authorization[7:].strip())


def resolve_org(caller: Dict[str, Any],
                org_id: Optional[str] = None) -> Tuple[str, str]:
    """Организация запроса + роль в ней (членство проверяется на сервере)."""
    orgs = caller.get("orgs") or []
    if not orgs:
        raise HTTPException(
            status_code=409,
            detail="У пользователя нет организации: создайте её в POST /auth/orgs")
    if org_id:
        for org in orgs:
            if org.get("org_id") == org_id:
                return org_id, str(org.get("role") or "member")
        raise HTTPException(status_code=403, detail="Нет доступа к организации")
    first = orgs[0]
    return str(first.get("org_id")), str(first.get("role") or "member")


def require_admin(role: str) -> None:
    if role not in ("owner", "admin"):
        raise HTTPException(status_code=403,
                            detail="Требуются права владельца или администратора")


# ---------- модели запросов ----------

class CheckoutIn(BaseModel):
    plan: str = Field(min_length=1, max_length=16)
    org_id: Optional[str] = Field(default=None, max_length=64)


class OrgIn(BaseModel):
    org_id: Optional[str] = Field(default=None, max_length=64)


class RefundIn(BaseModel):
    org_id: Optional[str] = Field(default=None, max_length=64)
    order_id: Optional[str] = Field(default=None, max_length=64)
    payment_id: Optional[str] = Field(default=None, max_length=64)
    amount_rub: Optional[int] = Field(default=None, ge=1)
    reason: Optional[str] = Field(default=None, max_length=256)


# ---------- app ----------

app = FastAPI(title="Препресс-Планер: billing (ЮKassa)", version="1.0.0")

try:
    ensure_schema()
except HTTPException as exc:  # сервис стартует, /healthz покажет проблему
    log_event("db_init_failed", error=exc.detail)


# ---------- тарифы ----------

@app.get("/payments/plans")
def plans() -> List[Dict[str, Any]]:
    return [{"plan": p["plan"], "title": p["title"], "amount_rub": p["amount_rub"],
             "days": p["days"], "currency": p["currency"],
             "features": p["features"]} for p in config.plan_list()]


@app.get("/payments/free-plan")
def free_plan() -> Dict[str, Any]:
    """Тариф Free и его лимиты гейтинга (F-22)."""
    return dict(config.FREE_PLAN)


# ---------- оплата ----------

@app.post("/payments/checkout")
def checkout(body: CheckoutIn, caller: Dict[str, Any] = Depends(auth_dep),
             provider: PaymentProvider = Depends(get_provider)) -> Dict[str, Any]:
    """Заказ (pending) + платёж ЮKassa → `confirmation_url`."""
    db_ready()
    plan = config.plan_info(body.plan)
    if plan is None:
        raise HTTPException(status_code=422, detail="Тариф: month или year")
    org_id, role = resolve_org(caller, body.org_id)
    order = STORE.create_order(org_id, str(caller.get("sub")), plan["plan"])
    try:
        payment = provider.create_payment(order, plan,
                                          config.return_url_for(order["id"]),
                                          customer_email=caller.get("email"))
    except ProviderNotConfigured as exc:
        STORE.fail_order(order["id"])
        log_event("checkout_unavailable", order_id=order["id"], org_id=org_id,
                  reason=str(exc))
        raise HTTPException(status_code=503, detail=str(exc))
    except ProviderError as exc:
        STORE.fail_order(order["id"])
        log_event("checkout_failed", order_id=order["id"], org_id=org_id,
                  reason=str(exc))
        raise HTTPException(status_code=502,
                            detail=f"Платёжный провайдер недоступен: {exc}")
    STORE.set_order_provider(order["id"], payment["provider_payment_id"],
                             payment["confirmation_url"])
    log_event("checkout_created", order_id=order["id"], org_id=org_id,
              user_id=caller.get("sub"), plan=plan["plan"], role=role,
              amount_rub=plan["amount_rub"], provider=provider.name)
    return {
        "order_id": order["id"],
        "org_id": org_id,
        "plan": plan["plan"],
        "plan_alias": config.subscription_plan_alias(plan["plan"]),
        "title": plan["title"],
        "amount_rub": plan["amount_rub"],
        "currency": plan["currency"],
        "days": plan["days"],
        "status": "pending",
        "confirmation_url": payment["confirmation_url"],
        "provider": provider.name,
    }


@app.get("/payments/orders/{order_id}")
def get_order(order_id: str, org_id: Optional[str] = Query(default=None),
              caller: Dict[str, Any] = Depends(auth_dep)) -> Dict[str, Any]:
    """Заказ организации (чужие заказы недоступны — 404)."""
    db_ready()
    org, _role = resolve_org(caller, org_id)
    order = STORE.get_order_for_org(order_id, org)
    if order is None:
        raise HTTPException(status_code=404, detail="Заказ не найден")
    return STORE.order_view(order)


@app.post("/payments/webhook")
async def webhook(request: FastAPIRequest,
                  provider: PaymentProvider = Depends(get_provider)) -> Dict[str, Any]:
    """Уведомление ЮKassa: подпись HMAC-SHA256 → идемпотентная обработка."""
    db_ready()
    raw = await request.body()
    if len(raw) > config.WEBHOOK_MAX_BYTES:
        raise HTTPException(status_code=413, detail="Слишком большое тело вебхука")
    try:
        event = provider.process_webhook(raw, request.headers)
    except ProviderNotConfigured as exc:
        log_event("webhook_not_configured", reason=str(exc))
        raise HTTPException(status_code=503, detail=str(exc))
    except WebhookSignatureError as exc:
        log_event("webhook_rejected", reason=str(exc))
        raise HTTPException(status_code=401, detail=str(exc))
    except WebhookPayloadError as exc:
        log_event("webhook_bad_payload", reason=str(exc))
        raise HTTPException(status_code=422, detail=str(exc))
    except ProviderError as exc:
        log_event("webhook_provider_error", reason=str(exc))
        raise HTTPException(status_code=502, detail=str(exc))

    name = event["event"]
    try:
        if name == "payment.succeeded":
            result = STORE.apply_payment_succeeded(event)
        elif name == "payment.canceled":
            result = STORE.apply_payment_canceled(event)
        elif name == "refund.succeeded":
            result = STORE.apply_refund_succeeded(event)
        else:
            result = {"ok": True, "ignored": name}
    except OrderNotFound as exc:
        log_event("webhook_unknown_order", event=name,
                  provider_payment_id=event.get("provider_payment_id"),
                  provider_order_id=event.get("provider_order_id"))
        raise HTTPException(status_code=404, detail=str(exc))
    except StoreError as exc:
        raise HTTPException(status_code=422, detail=str(exc))

    log_event("webhook_processed", event=name, order_id=result.get("order_id"),
              org_id=result.get("org_id"), already=result.get("already"),
              amount_rub=event.get("amount_rub"))
    return result


# ---------- подписка и права ----------

@app.get("/payments/subscription")
def subscription(org_id: Optional[str] = Query(default=None),
                 caller: Dict[str, Any] = Depends(auth_dep),
                 provider: PaymentProvider = Depends(get_provider)) -> Dict[str, Any]:
    """Текущее состояние подписки организации (источник истины — billing)."""
    db_ready()
    org, _role = resolve_org(caller, org_id)
    return provider.get_subscription(org)


@app.get("/payments/entitlement")
def entitlement(org_id: Optional[str] = Query(default=None),
                caller: Dict[str, Any] = Depends(auth_dep)) -> Dict[str, Any]:
    """Права организации (гейтинг UI: features, pro, trial_active)."""
    db_ready()
    org, _role = resolve_org(caller, org_id)
    return STORE.entitlement_view(org)


@app.get("/entitlement")
def entitlement_alias(org_id: Optional[str] = Query(default=None),
                      caller: Dict[str, Any] = Depends(auth_dep)) -> Dict[str, Any]:
    """Алиас `/payments/entitlement` для внутренних вызовов (auth/api)."""
    return entitlement(org_id=org_id, caller=caller)


@app.get("/payments/transactions")
def transactions(org_id: Optional[str] = Query(default=None),
                 limit: int = Query(default=20, ge=1, le=100),
                 caller: Dict[str, Any] = Depends(auth_dep)) -> Dict[str, Any]:
    """Журнал событий провайдера по организации (сверка/reconciliation)."""
    db_ready()
    org, _role = resolve_org(caller, org_id)
    return {"org_id": org, "items": STORE.transactions(org, limit)}


@app.post("/payments/subscription/cancel")
def cancel_subscription(body: Optional[OrgIn] = None,
                        org_id: Optional[str] = Query(default=None),
                        caller: Dict[str, Any] = Depends(auth_dep),
                        provider: PaymentProvider = Depends(get_provider)
                        ) -> Dict[str, Any]:
    """Отмена автопродления: права Pro сохраняются до конца оплаченного периода."""
    db_ready()
    requested = (body.org_id if body else None) or org_id
    org, _role = resolve_org(caller, requested)
    view = provider.cancel_subscription(org)
    log_event("subscription_cancel_at_period_end", org_id=org,
              until=view.get("until"))
    return {"ok": True, "cancel_at_period_end": view["cancel_at_period_end"],
            "until": view["until"], "status": view["status"],
            "subscription": view}


@app.post("/payments/subscription/resume")
def resume_subscription(body: Optional[OrgIn] = None,
                        org_id: Optional[str] = Query(default=None),
                        caller: Dict[str, Any] = Depends(auth_dep)) -> Dict[str, Any]:
    """Возобновление автопродления (в т.ч. после успешного платежа)."""
    db_ready()
    requested = (body.org_id if body else None) or org_id
    org, _role = resolve_org(caller, requested)
    view = STORE.set_cancel_at_period_end(org, False)
    log_event("subscription_resumed", org_id=org, until=view.get("until"))
    return {"ok": True, "cancel_at_period_end": view["cancel_at_period_end"],
            "until": view["until"], "status": view["status"],
            "subscription": view}


# ---------- возвраты ----------

def _do_refund(body: RefundIn, org_id: Optional[str],
               caller: Dict[str, Any], provider: PaymentProvider) -> Dict[str, Any]:
    db_ready()
    requested = body.org_id or org_id
    org, role = resolve_org(caller, requested)
    require_admin(role)

    order = None
    if body.order_id:
        order = STORE.get_order_for_org(body.order_id, org)
        if order is None:
            raise HTTPException(status_code=404, detail="Заказ не найден")
        if order["status"] not in ("paid", "refunded"):
            raise HTTPException(
                status_code=409,
                detail="Возврат возможен только по оплаченному заказу "
                       f"(статус: {order['status']})")

    payment_id = body.payment_id or (order["provider_order_id"] if order else None)
    if order is not None and not payment_id:
        raise HTTPException(status_code=409,
                            detail="У заказа нет связанного платежа провайдера")
    amount_rub = body.amount_rub or (order["amount_rub"] if order else None)
    if not payment_id or not amount_rub:
        last = STORE.last_paid_payment(org)
        if last is None:
            raise HTTPException(status_code=409,
                                detail="Нет успешных платежей для возврата")
        payment_id = payment_id or last["payment_id"]
        amount_rub = amount_rub or last["amount_rub"]

    try:
        result = provider.refund(payment_id, int(amount_rub),
                                 order_id=order["id"] if order else "",
                                 idempotence_key=str(body.order_id or payment_id))
    except ProviderNotConfigured as exc:
        raise HTTPException(status_code=503, detail=str(exc))
    except ProviderError as exc:
        log_event("refund_failed", org_id=org, order_id=order["id"] if order else None,
                  reason=str(exc))
        raise HTTPException(status_code=502,
                            detail=f"Возврат не выполнен: {exc}")

    refund_id = result["refund_id"]
    event = {
        "provider_payment_id": refund_id,
        "payment_id": payment_id,
        "order_id": order["id"] if order else None,
        "amount_rub": int(amount_rub),
        "currency": "RUB",
        "status": result.get("status") or "pending",
        "raw": result.get("raw") or {},
    }
    if event["status"] == "succeeded":
        # Права понижаются сразу; вебхук refund.succeeded идемпотентен по refund_id.
        applied = STORE.apply_refund_succeeded(event)
    else:
        # Возврат в обработке: фиксируем в журнале, права снимет вебхук.
        STORE.record_refund_request(refund_id, payment_id,
                                    order["id"] if order else None,
                                    int(amount_rub), event["status"],
                                    event["raw"])
        applied = {"ok": True, "pending": True}
    log_event("refund_created", org_id=org, order_id=order["id"] if order else None,
              refund_id=refund_id, amount_rub=amount_rub,
              status=event["status"], user_id=caller.get("sub"))
    return {"ok": True, "refund_id": refund_id, "status": event["status"],
            "amount_rub": int(amount_rub), "currency": "RUB",
            "order_id": order["id"] if order else None,
            "payment_id": payment_id, "applied": applied}


@app.post("/payments/subscription/refund")
def subscription_refund(body: RefundIn, org_id: Optional[str] = Query(default=None),
                        caller: Dict[str, Any] = Depends(auth_dep),
                        provider: PaymentProvider = Depends(get_provider)
                        ) -> Dict[str, Any]:
    """Возврат по подписке (owner/admin) — System Design §12.3."""
    return _do_refund(body, org_id, caller, provider)


@app.post("/payments/refunds")
def refunds(body: RefundIn, org_id: Optional[str] = Query(default=None),
            caller: Dict[str, Any] = Depends(auth_dep),
            provider: PaymentProvider = Depends(get_provider)) -> Dict[str, Any]:
    """Алиас `POST /payments/subscription/refund` (контракт task-spec)."""
    return _do_refund(body, org_id, caller, provider)


# ---------- health ----------

@app.get("/healthz")
def healthz() -> Dict[str, Any]:
    try:
        info = ensure_schema()
        db_state = {"ok": True, "target": info.get("db")}
    except HTTPException as exc:
        log_event("healthz_db_error", error=exc.detail)
        raise HTTPException(status_code=503,
                            detail={"status": "error", "service": config.SERVICE_NAME,
                                    "db": {"ok": False, "error": exc.detail},
                                    **PROVIDER.describe()})
    payload: Dict[str, Any] = {
        "status": "ok",
        "service": config.SERVICE_NAME,
        "version": app.version,
        "db": db_state,
        "plans": list(config.PLANS),
        "trial_days": config.TRIAL_DAYS,
        "prices_rub": {"month": config.MONTH_PRICE_RUB, "year": config.YEAR_PRICE_RUB},
    }
    payload.update(PROVIDER.describe())
    return payload
