# -*- coding: utf-8 -*-
"""Бизнес-логика billing: заказы, транзакции, подписка, триал, entitlements.

Основание: System Design v1 (ADR-3, §12.3, §13.2) и PRD v2 (F-20, F-21, F-22).

Модель:
  * `orders` — заказ организации на тариф (`pending` → `paid`/`canceled`/`failed`/
    `refunded`); связь с платежом провайдера — `provider_order_id`.
  * `transactions` — журнал событий провайдера; `provider_payment_id` UNIQUE
    (id платежа для `payment.*`, id возврата для `refund.*`) — идемпотентность.
  * `subscriptions` — одна подписка на организацию; `trialing/active/past_due/
    canceled/expired`, продление ВСЕГДА от конца текущего периода.
  * `entitlements` — проекция прав (Free/Pro), пересчитывается после каждого
    изменения (источник истины — subscriptions + transactions).

Триал 15 дней ведёт этот слой (не провайдер): при первом обращении организации
создаётся подписка `trialing`; платёж создаётся провайдером только по явному
checkout. Права: до конца триала — `trial_active=true` (права Pro), после
окончания без оплаты — Free, после успешной оплаты — Pro.
"""
from __future__ import annotations

import json
import time
import uuid
from datetime import datetime, timezone
from typing import Any, Dict, List, Optional, Tuple

from . import config
from .db import Database, is_unique_violation


class StoreError(RuntimeError):
    """Ошибка бизнес-логики billing (сообщение — русское)."""


class OrderNotFound(StoreError):
    """Заказ не найден (webhook по неизвестному provider_order_id)."""


# --------------------------------------------------------------------------
# Время: ISO-8601 UTC в TEXT (переносимо между SQLite и PostgreSQL)
# --------------------------------------------------------------------------

def now_epoch() -> float:
    return time.time()


def to_iso(ts: Optional[float]) -> Optional[str]:
    if ts is None:
        return None
    return datetime.fromtimestamp(float(ts), timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def from_iso(value: Any) -> Optional[float]:
    if not value:
        return None
    if isinstance(value, (int, float)):
        return float(value)
    text = str(value).strip()
    if text.endswith("Z"):
        text = text[:-1] + "+00:00"
    try:
        dt = datetime.fromisoformat(text)
    except ValueError:
        return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.timestamp()


def as_bool(value: Any) -> bool:
    if isinstance(value, bool):
        return value
    if value is None:
        return False
    return str(value).strip().lower() in ("1", "true", "t", "yes", "y")


def new_id() -> str:
    return uuid.uuid4().hex


class BillingStore:
    """Хранилище и правила billing поверх выбранной БД (SQLite/PostgreSQL)."""

    def __init__(self, db: Database) -> None:
        self.db = db

    # ------------------------------------------------------------------
    # Инициализация
    # ------------------------------------------------------------------
    def init(self) -> Dict[str, Any]:
        info = self.db.init_schema()
        with self.db.tx() as conn:
            self._seed_plans(conn)
        return info

    def _seed_plans(self, conn) -> None:
        """Таблица plans (System Design §13.2) синхронизируется с конфигом env."""
        stamp = to_iso(now_epoch())
        for plan in list(config.ALL_PLANS.values()):
            conn.execute(
                "INSERT INTO plans (plan, title, amount_rub, days, currency, "
                "features, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?) "
                "ON CONFLICT(plan) DO UPDATE SET title=excluded.title, "
                "amount_rub=excluded.amount_rub, days=excluded.days, "
                "currency=excluded.currency, features=excluded.features, "
                "updated_at=excluded.updated_at",
                (plan["plan"], plan["title"], plan["amount_rub"], plan["days"],
                 plan["currency"], json.dumps(plan["features"], ensure_ascii=False),
                 stamp))

    # ------------------------------------------------------------------
    # Подписка и триал
    # ------------------------------------------------------------------
    def _ensure_subscription(self, conn, org_id: str) -> Dict[str, Any]:
        """Подписка организации; при первом обращении стартует триал (15 дней)."""
        row = conn.query_one("SELECT * FROM subscriptions WHERE org_id = ?", (org_id,))
        if row is not None:
            return row
        now = now_epoch()
        stamp = to_iso(now)
        trial_end = to_iso(now + config.TRIAL_DAYS * 86400)
        conn.execute(
            "INSERT INTO subscriptions (id, org_id, plan, status, trial_started_at, "
            "trial_ends_at, current_period_start, current_period_end, "
            "cancel_at_period_end, provider_subscription_id, created_at, updated_at) "
            "VALUES (?, ?, 'free', 'trialing', ?, ?, NULL, NULL, ?, NULL, ?, ?)",
            (new_id(), org_id, stamp, trial_end, False, stamp, stamp))
        row = conn.query_one("SELECT * FROM subscriptions WHERE org_id = ?", (org_id,))
        assert row is not None
        self._recompute_entitlement(conn, org_id, row)
        return row

    def get_subscription_row(self, org_id: str) -> Dict[str, Any]:
        """Подписка с ленивым истечением (trialing/active → expired по времени)."""
        with self.db.tx() as conn:
            row = self._ensure_subscription(conn, org_id)
            row = self._expire_if_needed(conn, row)
            return row

    def _expire_if_needed(self, conn, row: Dict[str, Any]) -> Dict[str, Any]:
        now = now_epoch()
        status = row["status"]
        changed = False
        if status == "trialing":
            end = from_iso(row["trial_ends_at"])
            if end is not None and end <= now:
                status, changed = "expired", True
        elif status == "active":
            end = from_iso(row["current_period_end"])
            if end is not None and end <= now:
                status, changed = "expired", True
        if not changed:
            return row
        conn.execute("UPDATE subscriptions SET status = ?, updated_at = ? "
                     "WHERE org_id = ?", (status, to_iso(now), row["org_id"]))
        row = conn.query_one("SELECT * FROM subscriptions WHERE org_id = ?",
                             (row["org_id"],))
        assert row is not None
        self._recompute_entitlement(conn, row["org_id"], row)
        return row

    # ------------------------------------------------------------------
    # Права (entitlements)
    # ------------------------------------------------------------------
    @staticmethod
    def _rights(row: Optional[Dict[str, Any]], now: float) -> Dict[str, Any]:
        """Права организации: план, статус, features, до какого момента."""
        if row is None:
            return {"plan": "free", "status": "free", "pro": False,
                    "trial_active": False, "features": dict(config.FREE_FEATURES),
                    "until": None}
        status = row["status"]
        trial_end = from_iso(row["trial_ends_at"])
        period_end = from_iso(row["current_period_end"])
        trial_active = status == "trialing" and trial_end is not None and trial_end > now
        paid_active = status == "active" and period_end is not None and period_end > now

        if paid_active:
            return {"plan": "pro", "status": "pro", "pro": True,
                    "trial_active": False, "features": dict(config.PRO_FEATURES),
                    "until": to_iso(period_end)}
        if trial_active:
            return {"plan": "pro", "status": "pro", "pro": True,
                    "trial_active": True, "features": dict(config.PRO_FEATURES),
                    "until": to_iso(trial_end)}
        # Нет активной подписки (в т.ч. past_due/canceled/expired): права Free.
        until = period_end if period_end else trial_end
        return {"plan": "free", "status": "free", "pro": False,
                "trial_active": False, "features": dict(config.FREE_FEATURES),
                "until": to_iso(until)}

    def _recompute_entitlement(self, conn, org_id: str,
                               row: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
        if row is None:
            row = conn.query_one("SELECT * FROM subscriptions WHERE org_id = ?",
                                 (org_id,))
        rights = self._rights(row, now_epoch())
        stamp = to_iso(now_epoch())
        existing = conn.query_one("SELECT id FROM entitlements WHERE org_id = ?",
                                 (org_id,))
        ent_id = existing["id"] if existing else new_id()
        conn.execute(
            "INSERT INTO entitlements (id, org_id, plan, status, pro, features, "
            "\"until\", updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?) "
            "ON CONFLICT(org_id) DO UPDATE SET plan=excluded.plan, "
            "status=excluded.status, pro=excluded.pro, features=excluded.features, "
            "\"until\"=excluded.\"until\", updated_at=excluded.updated_at",
            (ent_id, org_id, rights["plan"], rights["status"], bool(rights["pro"]),
             json.dumps(rights["features"], ensure_ascii=False), rights["until"], stamp))
        out = dict(rights)
        out.update({"org_id": org_id, "updated_at": stamp})
        return out

    def entitlement_view(self, org_id: str) -> Dict[str, Any]:
        """GET /payments/entitlement: права организации (пересчёт + проекция)."""
        with self.db.tx() as conn:
            row = self._ensure_subscription(conn, org_id)
            row = self._expire_if_needed(conn, row)
            rights = self._recompute_entitlement(conn, org_id, row)
        return {
            "org_id": org_id,
            "plan": rights["plan"],
            "status": rights["status"],
            "pro": rights["pro"],
            "trial_active": rights["trial_active"],
            "features": rights["features"],
            "until": rights["until"],
            "plan_alias": config.subscription_plan_alias(row["plan"]),
            "subscription_status": row["status"],
            "updated_at": rights["updated_at"],
        }

    def _subscription_view(self, row: Dict[str, Any]) -> Dict[str, Any]:
        rights = self._rights(row, now_epoch())
        return {
            "org_id": row["org_id"],
            "plan": row["plan"],
            "plan_alias": config.subscription_plan_alias(row["plan"]),
            "status": row["status"],
            "pro": rights["pro"],
            "trial_active": rights["trial_active"],
            "trial_ends_at": row["trial_ends_at"],
            "trial_days": config.TRIAL_DAYS,
            "until": rights["until"],
            "current_period_start": row["current_period_start"],
            "current_period_end": row["current_period_end"],
            "current_period_ends_at": row["current_period_end"],
            "cancel_at_period_end": as_bool(row["cancel_at_period_end"]),
            "features": rights["features"],
            "updated_at": row["updated_at"],
        }

    def subscription_view(self, org_id: str) -> Dict[str, Any]:
        """GET /payments/subscription: текущее состояние подписки организации."""
        with self.db.tx() as conn:
            row = self._ensure_subscription(conn, org_id)
            row = self._expire_if_needed(conn, row)
            self._recompute_entitlement(conn, org_id, row)
        return self._subscription_view(row)

    # ------------------------------------------------------------------
    # Отмена / возобновление автопродления
    # ------------------------------------------------------------------
    def set_cancel_at_period_end(self, org_id: str, cancel: bool) -> Dict[str, Any]:
        with self.db.tx() as conn:
            row = self._ensure_subscription(conn, org_id)
            row = self._expire_if_needed(conn, row)
            conn.execute("UPDATE subscriptions SET cancel_at_period_end = ?, "
                         "updated_at = ? WHERE org_id = ?",
                         (bool(cancel), to_iso(now_epoch()), org_id))
            row = conn.query_one("SELECT * FROM subscriptions WHERE org_id = ?",
                                 (org_id,))
            assert row is not None
            self._recompute_entitlement(conn, org_id, row)
        return self._subscription_view(row)

    # ------------------------------------------------------------------
    # Заказы
    # ------------------------------------------------------------------
    def create_order(self, org_id: str, user_id: str, plan: str) -> Dict[str, Any]:
        info = config.plan_info(plan)
        if info is None:
            raise StoreError("Тариф: month или year")
        order_id = new_id()
        stamp = to_iso(now_epoch())
        with self.db.tx() as conn:
            self._ensure_subscription(conn, org_id)
            conn.execute(
                "INSERT INTO orders (id, org_id, user_id, plan, amount_rub, currency, "
                "status, provider_order_id, confirmation_url, created_at) "
                "VALUES (?, ?, ?, ?, ?, ?, 'pending', NULL, NULL, ?)",
                (order_id, org_id, user_id, info["plan"], info["amount_rub"],
                 info["currency"], stamp))
        return self.get_order(order_id)  # type: ignore[return-value]

    def get_order(self, order_id: str) -> Optional[Dict[str, Any]]:
        with self.db.read() as conn:
            return conn.query_one("SELECT * FROM orders WHERE id = ?", (order_id,))

    def get_order_for_org(self, order_id: str, org_id: str) -> Optional[Dict[str, Any]]:
        """Заказ в границах организации (изоляция тенантов, N-4)."""
        with self.db.read() as conn:
            return conn.query_one(
                "SELECT * FROM orders WHERE id = ? AND org_id = ?",
                (order_id, org_id))

    def set_order_provider(self, order_id: str, provider_order_id: str,
                           confirmation_url: str) -> None:
        with self.db.tx() as conn:
            conn.execute("UPDATE orders SET provider_order_id = ?, "
                         "confirmation_url = ? WHERE id = ?",
                         (provider_order_id, confirmation_url, order_id))

    def fail_order(self, order_id: str) -> None:
        with self.db.tx() as conn:
            conn.execute("UPDATE orders SET status = 'failed' WHERE id = ? AND "
                         "status = 'pending'", (order_id,))

    @staticmethod
    def order_view(order: Dict[str, Any]) -> Dict[str, Any]:
        status = config.ORDER_STATUS_ALIASES.get(order["status"], order["status"])
        return {
            "order_id": order["id"],
            "org_id": order["org_id"],
            "plan": order["plan"],
            "plan_alias": config.subscription_plan_alias(order["plan"]),
            "amount_rub": order["amount_rub"],
            "currency": order["currency"],
            "status": status,
            "status_alias": "succeeded" if status == "paid" else status,
            "confirmation_url": order["confirmation_url"],
            "created_at": order["created_at"],
            "paid_at": order["paid_at"],
            "refunded_at": order["refunded_at"],
        }

    # ------------------------------------------------------------------
    # Журнал транзакций (идемпотентность по provider_payment_id)
    # ------------------------------------------------------------------
    def _record_event(self, conn, provider_payment_id: str, event_type: str,
                      status: str, amount_rub: int, currency: str,
                      order_id: Optional[str], raw: Dict[str, Any]
                      ) -> Tuple[Dict[str, Any], bool]:
        """Записать событие провайдера. Возвращает (строка, нужно_применять).

        Идемпотентность: повторное событие с тем же `provider_payment_id` и тем же
        статусом не применяется повторно (UNIQUE + сравнение статуса).
        """
        payload = json.dumps(raw, ensure_ascii=False, default=str)
        existing = conn.query_one(
            "SELECT * FROM transactions WHERE provider_payment_id = ?",
            (provider_payment_id,))
        if existing is not None:
            if existing["status"] == status:
                return existing, False
            conn.execute(
                "UPDATE transactions SET event_type = ?, amount_rub = ?, currency = ?, "
                "status = ?, raw_payload = ? WHERE provider_payment_id = ?",
                (event_type, amount_rub, currency, status, payload,
                 provider_payment_id))
            row = conn.query_one(
                "SELECT * FROM transactions WHERE provider_payment_id = ?",
                (provider_payment_id,))
            return row, True
        conn.execute(
            "INSERT INTO transactions (id, order_id, provider_payment_id, event_type, "
            "amount_rub, currency, status, raw_payload, received_at) "
            "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
            (new_id(), order_id, provider_payment_id, event_type, amount_rub,
             currency, status, payload, to_iso(now_epoch())))
        row = conn.query_one(
            "SELECT * FROM transactions WHERE provider_payment_id = ?",
            (provider_payment_id,))
        assert row is not None
        return row, True

    # ------------------------------------------------------------------
    # Обработка событий провайдера
    # ------------------------------------------------------------------
    def apply_payment_succeeded(self, event: Dict[str, Any]) -> Dict[str, Any]:
        """payment.succeeded: транзакция + продление подписки + entitlement."""
        payment_id = str(event.get("provider_payment_id") or "")
        if not payment_id:
            raise StoreError("В событии нет provider_payment_id")
        try:
            with self.db.tx() as conn:
                existing = conn.query_one(
                    "SELECT * FROM transactions WHERE provider_payment_id = ?",
                    (payment_id,))
                if existing is not None and existing["status"] == "succeeded":
                    return {"ok": True, "already": True, "order_id": existing["order_id"]}

                order = self._find_order(conn, event)
                if order is None:
                    raise OrderNotFound(
                        "Заказ не найден по provider_order_id="
                        f"{event.get('provider_order_id') or '-'}")

                amount_rub = int(event.get("amount_rub") or order["amount_rub"])
                currency = event.get("currency") or order["currency"]
                _, apply = self._record_event(
                    conn, payment_id, "payment.succeeded", "succeeded", amount_rub,
                    currency, order["id"], event.get("raw") or {})

                now = now_epoch()
                if order["status"] not in ("paid", "refunded"):
                    conn.execute("UPDATE orders SET status = 'paid', paid_at = ?, "
                                 "amount_rub = ? WHERE id = ?",
                                 (to_iso(now), amount_rub, order["id"]))
                if apply:
                    row = self._extend_period(conn, order["org_id"], order["plan"],
                                              event.get("payment_method_id"))
                    self._recompute_entitlement(conn, order["org_id"], row)
                    return {"ok": True, "already": False, "order_id": order["id"],
                            "org_id": order["org_id"], "plan": order["plan"],
                            "subscription": self._subscription_view(row)}
                row = conn.query_one("SELECT * FROM subscriptions WHERE org_id = ?",
                                     (order["org_id"],))
                return {"ok": True, "already": False, "order_id": order["id"],
                        "org_id": order["org_id"],
                        "subscription": self._subscription_view(row) if row else None}
        except Exception as exc:  # noqa: BLE001 — уникальность как признак дубля
            if is_unique_violation(exc):
                return {"ok": True, "already": True}
            raise

    def _find_order(self, conn, event: Dict[str, Any]) -> Optional[Dict[str, Any]]:
        provider_order_id = str(event.get("provider_order_id") or "").strip()
        order = None
        if provider_order_id:
            order = conn.query_one("SELECT * FROM orders WHERE provider_order_id = ?",
                                   (provider_order_id,))
        if order is None:
            order_id = str(event.get("order_id") or "").strip()
            if order_id:
                order = conn.query_one("SELECT * FROM orders WHERE id = ?", (order_id,))
                # Догоняем provider_order_id, если ответ ЮKassa не успел сохраниться.
                if order is not None and not order["provider_order_id"] and provider_order_id:
                    conn.execute("UPDATE orders SET provider_order_id = ? WHERE id = ?",
                                 (provider_order_id, order["id"]))
        return order

    def _extend_period(self, conn, org_id: str, plan: str,
                       provider_subscription_id: Optional[str] = None
                       ) -> Dict[str, Any]:
        """Продление подписки от конца текущего периода (System Design ADR-3)."""
        info = config.plan_info(plan)
        if info is None:
            raise StoreError(f"Неизвестный тариф заказа: {plan}")
        row = self._ensure_subscription(conn, org_id)
        now = now_epoch()
        period_end = from_iso(row["current_period_end"])
        base = period_end if (row["status"] == "active" and period_end and
                              period_end > now) else now
        end = base + info["days"] * 86400
        conn.execute(
            "UPDATE subscriptions SET plan = ?, status = 'active', "
            "current_period_start = ?, current_period_end = ?, "
            "cancel_at_period_end = ?, provider_subscription_id = COALESCE(?, "
            "provider_subscription_id), updated_at = ? WHERE org_id = ?",
            (info["plan"], to_iso(base), to_iso(end), False,
             provider_subscription_id, to_iso(now), org_id))
        updated = conn.query_one("SELECT * FROM subscriptions WHERE org_id = ?",
                                 (org_id,))
        assert updated is not None
        return updated

    def apply_payment_canceled(self, event: Dict[str, Any]) -> Dict[str, Any]:
        """payment.canceled: неуспешная оплата/рекуррент → заказ canceled."""
        payment_id = str(event.get("provider_payment_id") or "")
        if not payment_id:
            raise StoreError("В событии нет provider_payment_id")
        with self.db.tx() as conn:
            existing = conn.query_one(
                "SELECT * FROM transactions WHERE provider_payment_id = ?",
                (payment_id,))
            if existing is not None and existing["status"] == "canceled":
                return {"ok": True, "already": True, "order_id": existing["order_id"]}
            order = self._find_order(conn, event)
            if order is None:
                raise OrderNotFound("Заказ не найден для payment.canceled")
            self._record_event(conn, payment_id, "payment.canceled", "canceled",
                               int(event.get("amount_rub") or order["amount_rub"]),
                               event.get("currency") or order["currency"],
                               order["id"], event.get("raw") or {})
            if order["status"] == "pending":
                conn.execute("UPDATE orders SET status = 'canceled' WHERE id = ?",
                             (order["id"],))
            # Просроченное автопродление: подписка была активна, период кончился.
            sub = conn.query_one("SELECT * FROM subscriptions WHERE org_id = ?",
                                 (order["org_id"],))
            if sub is not None and sub["status"] == "active":
                end = from_iso(sub["current_period_end"])
                if end is not None and end <= now_epoch():
                    conn.execute("UPDATE subscriptions SET status = 'past_due', "
                                 "updated_at = ? WHERE org_id = ?",
                                 (to_iso(now_epoch()), order["org_id"]))
                    self._recompute_entitlement(conn, order["org_id"])
            return {"ok": True, "already": False, "order_id": order["id"],
                    "org_id": order["org_id"]}

    def apply_refund_succeeded(self, event: Dict[str, Any]) -> Dict[str, Any]:
        """refund.succeeded (или ответ POST /refunds): права возвращаются к Free."""
        refund_id = str(event.get("provider_payment_id") or "")
        if not refund_id:
            raise StoreError("В событии возврата нет provider_payment_id")
        payment_id = str(event.get("payment_id") or "").strip()
        with self.db.tx() as conn:
            existing = conn.query_one(
                "SELECT * FROM transactions WHERE provider_payment_id = ?",
                (refund_id,))
            if existing is not None and existing["status"] == "succeeded":
                return {"ok": True, "already": True, "order_id": existing["order_id"]}
            order = None
            if payment_id:
                order = conn.query_one(
                    "SELECT * FROM orders WHERE provider_order_id = ?", (payment_id,))
            if order is None:
                order_id = str(event.get("order_id") or "").strip()
                if order_id:
                    order = conn.query_one("SELECT * FROM orders WHERE id = ?",
                                           (order_id,))
            amount_rub = int(event.get("amount_rub") or (order["amount_rub"] if order
                                                         else 0))
            self._record_event(conn, refund_id, "refund.succeeded", "succeeded",
                               amount_rub, event.get("currency") or "RUB",
                               order["id"] if order else None, event.get("raw") or {})
            if order is None:
                # Возврат по платежу, которого нет в billing: фиксируем в журнале.
                return {"ok": True, "already": False, "order_found": False}
            now = now_epoch()
            conn.execute("UPDATE orders SET status = 'refunded', refunded_at = ? "
                         "WHERE id = ?", (to_iso(now), order["id"]))
            self._ensure_subscription(conn, order["org_id"])
            # Возврат снимает права: подписка отменяется, период закрывается сейчас.
            conn.execute("UPDATE subscriptions SET status = 'canceled', "
                         "current_period_end = ?, cancel_at_period_end = ?, "
                         "updated_at = ? WHERE org_id = ?",
                         (to_iso(now), False, to_iso(now), order["org_id"]))
            row = conn.query_one("SELECT * FROM subscriptions WHERE org_id = ?",
                                 (order["org_id"],))
            assert row is not None
            self._recompute_entitlement(conn, order["org_id"], row)
            return {"ok": True, "already": False, "order_found": True,
                    "order_id": order["id"], "org_id": order["org_id"],
                    "subscription": self._subscription_view(row),
                    "entitlement": self._rights(row, now)}

    # ------------------------------------------------------------------
    # Данные для возврата
    # ------------------------------------------------------------------
    def record_refund_request(self, refund_id: str, payment_id: str,
                              order_id: Optional[str], amount_rub: int,
                              status: str, raw: Dict[str, Any]) -> Dict[str, Any]:
        """Зафиксировать возврат, ещё не подтверждённый провайдером.

        Права НЕ понижаются: итоговое `refund.succeeded` придёт вебхуком и
        применит переход (идемпотентность — по `refund_id`).
        """
        with self.db.tx() as conn:
            row, created = self._record_event(
                conn, refund_id, "refund.requested", status, amount_rub, "RUB",
                order_id, raw)
        return {"ok": True, "refund_id": refund_id, "status": row["status"],
                "created": created}

    def last_paid_payment(self, org_id: str) -> Optional[Dict[str, Any]]:
        """Последний успешный платёж организации (для POST /refunds)."""
        with self.db.read() as conn:
            return conn.query_one(
                "SELECT t.provider_payment_id AS payment_id, t.amount_rub AS amount_rub, "
                "t.currency AS currency, t.received_at AS received_at, o.id AS order_id, "
                "o.plan AS plan, o.status AS order_status "
                "FROM transactions t JOIN orders o ON o.id = t.order_id "
                "WHERE o.org_id = ? AND t.event_type = 'payment.succeeded' "
                "AND t.status = 'succeeded' "
                "ORDER BY t.received_at DESC LIMIT 1", (org_id,))

    def transactions(self, org_id: str, limit: int = 20) -> List[Dict[str, Any]]:
        with self.db.read() as conn:
            rows = conn.query(
                "SELECT t.provider_payment_id, t.event_type, t.amount_rub, t.currency, "
                "t.status, t.received_at, t.order_id FROM transactions t "
                "JOIN orders o ON o.id = t.order_id WHERE o.org_id = ? "
                "ORDER BY t.received_at DESC LIMIT ?", (org_id, int(limit)))
        return rows
