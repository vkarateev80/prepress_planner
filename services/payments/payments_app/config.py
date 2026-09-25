# -*- coding: utf-8 -*-
"""Конфигурация billing-сервиса «Препресс-Планер» (только env, без секретов в коде).

Основание: PRD v2 (F-20, F-21) и System Design v1 (ADR-3, §12.3, §13.2).

Здесь собраны все настройки: адрес auth, БД, ключи ЮKassa, тарифы и триал.
Секреты (YUKASSA_SECRET_KEY, YUKASSA_WEBHOOK_SECRET) читаются ТОЛЬКО из env и
никогда не попадают в ответы API/логи.

env:
  PP_AUTH_URL              — адрес auth (обязателен; в docker http://auth:8121)
  DB_URL                   — postgresql://… (System Design §13); пусто → SQLite
  PP_DATA_DIR              — каталог SQLite (PP_DATA_DIR/payments.db)
  YUKASSA_SHOP_ID          — shopId ЮKassa
  YUKASSA_SECRET_KEY       — секретный ключ ЮKassa (Basic auth)
  YUKASSA_WEBHOOK_SECRET   — секрет HMAC-SHA256 для подписи вебхуков
  YUKASSA_API_URL          — базовый URL API (по умолчанию https://api.yookassa.ru/v3)
  YUKASSA_SAVE_PAYMENT_METHOD — 1 = просить ЮKassa сохранить способ оплаты
                             (автоплатежи; нужна активация у мерчанта)
  PP_PUBLIC_BASE           — публичный origin для return_url (ADR-6, 443)
  PP_RETURN_PATH           — путь возврата после оплаты (по умолчанию /billing/return)
  PP_TRIAL_DAYS            — срок триала в днях (по умолчанию 15, вне провайдера)
  PP_PRO_MONTH_PRICE_RUB   — цена Pro-месяца (990)
  PP_PRO_YEAR_PRICE_RUB    — цена Pro-года (9900)
  PP_WEBHOOK_MAX_BYTES     — лимит тела вебхука (65536)
"""
from __future__ import annotations

import os
from typing import Any, Dict, List, Optional

SERVICE_NAME = "billing"


def _env(name: str, default: str = "") -> str:
    return (os.environ.get(name) or default).strip()


def _env_int(name: str, default: int) -> int:
    raw = _env(name)
    if not raw:
        return default
    try:
        return int(float(raw))
    except ValueError:
        raise RuntimeError(f"{name}: ожидалось целое число, получено {raw!r}")


# ---------- зависимости ----------

AUTH_URL = _env("PP_AUTH_URL").rstrip("/")
if not AUTH_URL:
    raise RuntimeError("PP_AUTH_URL обязателен (адрес микросервиса auth)")

DB_URL = _env("DB_URL")
DATA_DIR = _env("PP_DATA_DIR")

PUBLIC_BASE = _env("PP_PUBLIC_BASE").rstrip("/")
RETURN_PATH = _env("PP_RETURN_PATH", "/billing/return") or "/billing/return"
# return_url для ЮKassa: либо явный PP_RETURN_URL, либо собранный из публичного origin.
RETURN_URL = _env("PP_RETURN_URL") or (PUBLIC_BASE + RETURN_PATH if PUBLIC_BASE else "")

# ---------- ЮKassa ----------

YUKASSA_SHOP_ID = _env("YUKASSA_SHOP_ID")
YUKASSA_SECRET_KEY = _env("YUKASSA_SECRET_KEY")
YUKASSA_WEBHOOK_SECRET = _env("YUKASSA_WEBHOOK_SECRET")
YUKASSA_API_URL = (_env("YUKASSA_API_URL", "https://api.yookassa.ru/v3") or
                   "https://api.yookassa.ru/v3").rstrip("/")
# Автоплатежи (save_payment_method) включаются у ЮKassa только после активации
# рекуррента у мерчанта — по умолчанию выключены.
SAVE_PAYMENT_METHOD = _env("YUKASSA_SAVE_PAYMENT_METHOD").lower() in ("1", "true", "yes")

# ЮKassa включена только когда заданы оба ключа; иначе checkout/refund → 503
# (никаких «тестовых подтверждений» на стороне сервиса — см. ADR-3).
YUKASSA_CONFIGURED = bool(YUKASSA_SHOP_ID and YUKASSA_SECRET_KEY)

# ---------- триал и тарифы ----------

TRIAL_DAYS = _env_int("PP_TRIAL_DAYS", 15)
MONTH_PRICE_RUB = _env_int("PP_PRO_MONTH_PRICE_RUB", 990)
YEAR_PRICE_RUB = _env_int("PP_PRO_YEAR_PRICE_RUB", 9900)

WEBHOOK_MAX_BYTES = _env_int("PP_WEBHOOK_MAX_BYTES", 65536)

# Карта гейтинга (F-22, System Design §12.3).
FREE_FEATURES: Dict[str, Any] = {"projects": 1, "teo": False, "reports": False}
PRO_FEATURES: Dict[str, Any] = {"projects": None, "teo": True, "reports": True}

# Тарифы: ключ — каноническое имя плана (как в System Design §12.3).
PLANS: Dict[str, Dict[str, Any]] = {
    "month": {
        "plan": "month",
        "title": "Pro на месяц",
        "amount_rub": MONTH_PRICE_RUB,
        "days": 30,
        "currency": "RUB",
        "features": dict(PRO_FEATURES),
    },
    "year": {
        "plan": "year",
        "title": "Pro на год",
        "amount_rub": YEAR_PRICE_RUB,
        "days": 365,
        "currency": "RUB",
        "features": dict(PRO_FEATURES),
    },
}

# Тариф Free — не продаётся, но присутствует в таблице plans (System Design §13.2).
FREE_PLAN: Dict[str, Any] = {
    "plan": "free",
    "title": "Free (ограниченный)",
    "amount_rub": 0,
    "days": 0,
    "currency": "RUB",
    "features": dict(FREE_FEATURES),
}

ALL_PLANS: Dict[str, Dict[str, Any]] = {"free": FREE_PLAN, **PLANS}

# Синонимы планов (совместимость имён: task-spec использует pro_month/pro_year).
PLAN_ALIASES: Dict[str, str] = {
    "month": "month",
    "pro_month": "month",
    "monthly": "month",
    "year": "year",
    "pro_year": "year",
    "yearly": "year",
    "free": "free",
}

# Статусы подписки: канонические значения — System Design §12.3/§13.2;
# синоним «trial» принимается на входе и нормализуется в «trialing».
SUBSCRIPTION_STATUSES = ("trialing", "active", "past_due", "canceled", "expired")
STATUS_ALIASES = {"trial": "trialing", "trialing": "trialing",
                  "active": "active", "past_due": "past_due",
                  "canceled": "canceled", "cancelled": "canceled",
                  "expired": "expired"}

# Статусы заказа: канонический успешный — «paid» (System Design §13.2);
# «succeeded» (task-spec) — синоним, принимается и на входе, и в ответе.
ORDER_STATUSES = ("pending", "paid", "canceled", "failed", "refunded")
ORDER_STATUS_ALIASES = {"succeeded": "paid", "paid": "paid", "pending": "pending",
                        "canceled": "canceled", "cancelled": "canceled",
                        "failed": "failed", "refunded": "refunded"}


def normalize_plan(value: Optional[str]) -> Optional[str]:
    """«pro_month»/«month»/«monthly» → «month» (None, если план неизвестен)."""
    if value is None:
        return None
    return PLAN_ALIASES.get(str(value).strip().lower())


def normalize_subscription_status(value: Optional[str]) -> Optional[str]:
    if value is None:
        return None
    return STATUS_ALIASES.get(str(value).strip().lower())


def subscription_plan_alias(plan: Optional[str]) -> str:
    """Канонический ключ → имя «pro_month»/«pro_year»/«free» (как в task-spec)."""
    if plan in ("month", "year"):
        return f"pro_{plan}"
    return plan or "free"


def plan_list() -> List[Dict[str, Any]]:
    return [dict(p) for p in PLANS.values()]


def plan_info(plan: Optional[str]) -> Optional[Dict[str, Any]]:
    key = normalize_plan(plan)
    return PLANS.get(key) if key else None


def return_url_for(order_id: str) -> str:
    """return_url для confirmation ЮKassa (пусто, если публичный origin не задан)."""
    if not RETURN_URL:
        return ""
    sep = "&" if "?" in RETURN_URL else "?"
    return f"{RETURN_URL}{sep}order_id={order_id}"
