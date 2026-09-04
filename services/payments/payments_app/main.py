# -*- coding: utf-8 -*-
"""Микросервис оплаты «Препресс-Планер» (заглушка до подключения провайдера).

Тарифы Pro: месяц/год. Поток:
  1) POST /payments/checkout {plan} (Bearer) → создаёт заказ {order_id, amount,
     status: pending, url: "тестовая ссылка оплаты"};
  2) клиент «оплачивает» тестовой кнопкой → POST /payments/orders/{id}/confirm
     (Bearer) — помечает заказ paid и продлевает подписку;
  3) POST /payments/webhook — заглушка вебхука провайдера (по order_id);
  4) GET /payments/subscription (Bearer) → {plan, pro, until}.

Токены проверяются той же HMAC-подписью, что и в auth (общий PP_AUTH_SECRET) —
сервисы не ходят друг к другу по HTTP. Пользователь идентифицируется по
claim «sub» токена. Хранилище — SQLite (PP_DATA_DIR/payments.db).

env:
  PP_AUTH_SECRET — общий секрет с auth (обязателен)
  PP_DATA_DIR    — каталог БД
  PP_PUBLIC_BASE — публичный адрес сервиса для url оплаты (по умолчанию пусто)
"""
import json
import os
import secrets
import sqlite3
import threading
import time
import uuid
from contextlib import asynccontextmanager
from pathlib import Path

from fastapi import Depends, FastAPI, Header, HTTPException
from pydantic import BaseModel, Field

BASE = Path(__file__).resolve().parent.parent
DATA = Path(os.environ.get("PP_DATA_DIR") or (BASE / "data"))
DATA.mkdir(parents=True, exist_ok=True)
DB_PATH = DATA / "payments.db"

SECRET = os.environ.get("PP_AUTH_SECRET", "").strip()
if len(SECRET) < 16:
    raise RuntimeError("PP_AUTH_SECRET обязателен (≥ 16 символов)")
PUBLIC_BASE = os.environ.get("PP_PUBLIC_BASE", "").strip().rstrip("/")

_db_lock = threading.Lock()

# Тарифы: цена в рублях, срок подписки в днях.
PLANS = {
    "month": {"price_rub": 990, "days": 30, "title": "Pro на месяц"},
    "year": {"price_rub": 9900, "days": 365, "title": "Pro на год"},
}


def _connect() -> sqlite3.Connection:
    conn = sqlite3.connect(str(DB_PATH), check_same_thread=False)
    conn.row_factory = sqlite3.Row
    return conn


def _init_db():
    with _db_lock, _connect() as conn:
        conn.executescript(
            """
            CREATE TABLE IF NOT EXISTS orders (
                id TEXT PRIMARY KEY,
                user_id TEXT NOT NULL,
                plan TEXT NOT NULL,
                amount_rub INTEGER NOT NULL,
                status TEXT NOT NULL,      -- pending | paid | cancelled
                created_at REAL NOT NULL,
                paid_at REAL
            );
            CREATE TABLE IF NOT EXISTS subscriptions (
                user_id TEXT PRIMARY KEY,
                plan TEXT,
                until REAL,
                updated_at REAL
            );
            CREATE INDEX IF NOT EXISTS idx_orders_user ON orders(user_id);
            """
        )


# ---------- токены ----------

def _auth_dep(authorization: str | None = Header(default=None)) -> dict:
    if not authorization or not authorization.startswith("Bearer "):
        raise HTTPException(status_code=401, detail="Требуется токен")
    token = authorization[7:].strip()
    try:
        sig, body = token.split(".", 1)
        import hashlib
        import hmac
        expect = hmac.new(SECRET.encode(), body.encode(),
                          hashlib.sha256).hexdigest()
        if not hmac.compare_digest(sig, expect):
            raise ValueError("bad signature")
        payload = json.loads(body)
        if int(payload.get("exp", 0)) < int(time.time()):
            raise ValueError("expired")
        return {"sub": payload["sub"], "email": payload.get("email")}
    except Exception as e:  # noqa: BLE001
        raise HTTPException(status_code=401, detail=f"Недействительный токен: {e}")


# ---------- модели ----------

class CheckoutIn(BaseModel):
    plan: str = Field(min_length=1, max_length=16)


# ---------- app ----------

app = FastAPI(title="Препресс-Планер: оплата", version="0.1.0")
_init_db()


def _plan_or_404(plan: str) -> dict:
    p = PLANS.get(plan)
    if p is None:
        raise HTTPException(status_code=422,
                            detail="Тариф: month или year")
    return p


def _sub_dict(row) -> dict:
    if row is None or row["until"] is None:
        return {"plan": None, "pro": False, "until": None}
    until = row["until"]
    return {"plan": row["plan"], "pro": until > time.time(),
            "until": until}


@app.post("/payments/checkout")
def checkout(body: CheckoutIn, user: dict = Depends(_auth_dep)):
    p = _plan_or_404(body.plan)
    order_id = uuid.uuid4().hex[:16]
    with _db_lock, _connect() as conn:
        conn.execute(
            "INSERT INTO orders (id, user_id, plan, amount_rub, status, "
            "created_at) VALUES (?, ?, ?, ?, 'pending', ?)",
            (order_id, user["sub"], body.plan, p["price_rub"], time.time()))
    url = f"{PUBLIC_BASE}/pay/order/{order_id}" if PUBLIC_BASE else None
    return {
        "order_id": order_id,
        "plan": body.plan,
        "title": p["title"],
        "amount_rub": p["price_rub"],
        "status": "pending",
        "url": url,
        "hint": "Заглушка: подтвердите оплату через /payments/orders/{id}/confirm",
    }


@app.post("/payments/orders/{order_id}/confirm")
def confirm_order(order_id: str, user: dict = Depends(_auth_dep)):
    with _db_lock, _connect() as conn:
        row = conn.execute(
            "SELECT * FROM orders WHERE id = ? AND user_id = ?",
            (order_id, user["sub"])).fetchone()
        if row is None:
            raise HTTPException(status_code=404, detail="Заказ не найден")
        if row["status"] == "paid":
            raise HTTPException(status_code=409,
                                detail="Заказ уже оплачен")
        if row["status"] != "pending":
            raise HTTPException(status_code=409,
                                detail=f"Статус заказа: {row['status']}")
        plan = row["plan"]
        days = PLANS[plan]["days"]
        now = time.time()
        # Продление от конца текущей подписки (если активна), иначе от сейчас.
        sub = conn.execute(
            "SELECT until FROM subscriptions WHERE user_id = ?",
            (user["sub"],)).fetchone()
        base = sub["until"] if (sub is not None and sub["until"] and
                                sub["until"] > now) else now
        until = base + days * 86400
        conn.execute(
            "INSERT INTO subscriptions (user_id, plan, until, updated_at) "
            "VALUES (?, ?, ?, ?) "
            "ON CONFLICT(user_id) DO UPDATE SET plan=excluded.plan, "
            "until=excluded.until, updated_at=excluded.updated_at",
            (user["sub"], plan, until, now))
        conn.execute(
            "UPDATE orders SET status='paid', paid_at=? WHERE id=?",
            (now, order_id))
    return {"ok": True, "order_id": order_id, "plan": plan,
            "until": until}


@app.post("/payments/webhook")
def webhook(body: dict):
    """Заглушка вебхука платёжного провайдера: {order_id} → оплата."""
    order_id = str(body.get("order_id") or "").strip()
    if not order_id:
        raise HTTPException(status_code=422, detail="Нет order_id")
    with _db_lock, _connect() as conn:
        row = conn.execute(
            "SELECT * FROM orders WHERE id = ?", (order_id,)).fetchone()
        if row is None:
            raise HTTPException(status_code=404, detail="Заказ не найден")
        if row["status"] == "paid":
            return {"ok": True, "already": True}
        plan = row["plan"]
        days = PLANS[plan]["days"]
        now = time.time()
        sub = conn.execute(
            "SELECT until FROM subscriptions WHERE user_id = ?",
            (row["user_id"],)).fetchone()
        base = sub["until"] if (sub is not None and sub["until"] and
                                sub["until"] > now) else now
        until = base + days * 86400
        conn.execute(
            "INSERT INTO subscriptions (user_id, plan, until, updated_at) "
            "VALUES (?, ?, ?, ?) "
            "ON CONFLICT(user_id) DO UPDATE SET plan=excluded.plan, "
            "until=excluded.until, updated_at=excluded.updated_at",
            (row["user_id"], plan, until, now))
        conn.execute(
            "UPDATE orders SET status='paid', paid_at=? WHERE id=?",
            (now, order_id))
    return {"ok": True, "order_id": order_id, "until": until}


@app.get("/payments/subscription")
def subscription(user: dict = Depends(_auth_dep)):
    with _db_lock, _connect() as conn:
        row = conn.execute(
            "SELECT plan, until FROM subscriptions WHERE user_id = ?",
            (user["sub"],)).fetchone()
    return _sub_dict(row)


@app.get("/payments/plans")
def plans():
    return [{"plan": k, "title": v["title"], "amount_rub": v["price_rub"]}
            for k, v in PLANS.items()]


@app.get("/healthz")
def healthz():
    return {"status": "ok", "service": "payments",
            "db": str(DB_PATH), "plans": list(PLANS)}
