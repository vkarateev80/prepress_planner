# -*- coding: utf-8 -*-
"""Криптография: подпись офлайн-токенов (HMAC-SHA256), machine-id hash."""
import base64
import datetime
import hashlib
import hmac
import json
import os

# Формат: base64url(payload).base64url(signature), payload = JSON
# {machine_id, until, tier, iat}. Валиден 30 дней с даты выдачи (грэйс).

GRACE_DAYS = 30


def machine_hash(machine_id: str) -> str:
    """Стабильный хеш machine-id (не храним сырой id в ключах)."""
    return hashlib.sha256(machine_id.encode("utf-8")).hexdigest()[:24]


def _b64(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def _unb64(s: str) -> bytes:
    pad = "=" * (-len(s) % 4)
    return base64.urlsafe_b64decode(s + pad)


def sign_token(machine_id: str, until: str, tier: str,
               secret: str, iat: str | None = None) -> str:
    """Подпись офлайн-токена. until/iat — ISO-строки (naive UTC)."""
    from . import models
    if iat is None:
        iat = models.utcnow().isoformat()
    payload = {"machine_id": machine_id, "until": until,
               "tier": tier, "iat": iat}
    raw = json.dumps(payload, separators=(",", ":"), ensure_ascii=False)
    body = _b64(raw.encode("utf-8"))
    sig = hmac.new(secret.encode("utf-8"), body.encode("ascii"),
                   hashlib.sha256).digest()
    return f"{body}.{_b64(sig)}"


def verify_token(token: str, secret: str) -> dict | None:
    """Проверка подписи, срока действия и грэйса 30 дней."""
    from . import models
    try:
        body, sig = token.split(".")
        expected = hmac.new(secret.encode("utf-8"), body.encode("ascii"),
                            hashlib.sha256).digest()
        if not hmac.compare_digest(_unb64(sig), expected):
            return None
        payload = json.loads(_unb64(body).decode("utf-8"))
        until = datetime.datetime.fromisoformat(payload["until"])
        iat = datetime.datetime.fromisoformat(payload["iat"])
        now = models.utcnow()
        if until < now:
            return None
        if now - iat > datetime.timedelta(days=GRACE_DAYS):
            return None
        return payload
    except Exception:
        return None


def generate_key() -> str:
    """Ключ формата XXXX-XXXX-XXXX-XXXX."""
    import secrets
    alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
    groups = []
    for _ in range(4):
        groups.append("".join(secrets.choice(alphabet) for _ in range(4)))
    return "-".join(groups)


def signing_secret() -> str:
    """Секрет подписи: из окружения или авто-генерация (dev)."""
    return os.environ.get("PP_LICENSE_SECRET", "dev-secret-change-me")
