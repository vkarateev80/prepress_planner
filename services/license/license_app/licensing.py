# -*- coding: utf-8 -*-
"""Ядро лицензионной логики: триал 15 дней, ключи, подписки, токены."""
import datetime

from . import crypto
from .models import (
    Activation, Device, LicenseKey, Subscription, utcnow,
)


def _trial_expiry(start: datetime.datetime) -> datetime.datetime:
    return start + datetime.timedelta(days=15)


def _iso(dt: datetime.datetime | None) -> str | None:
    return dt.isoformat() if dt else None


def activate(db, machine_id: str, key: str | None, secret: str) -> dict:
    """Активация: без ключа — триал 15 дней; с ключом — подписка по ключу."""
    device = db.query(Device).filter_by(machine_id=machine_id).first()
    now = utcnow()

    if not key:
        if device is None:
            device = Device(
                machine_id=machine_id,
                trial_started_at=now,
                trial_expires_at=_trial_expiry(now),
            )
            db.add(device)
            db.commit()
            db.refresh(device)
            token = crypto.sign_token(
                machine_id, device.trial_expires_at.isoformat(),
                "trial", secret)
            return {"status": "trial", "expires_at": _iso(device.trial_expires_at),
                    "offline_token": token}
        # Повторная активация: триал уже есть.
        if device.trial_expires_at and device.trial_expires_at > now:
            token = crypto.sign_token(
                machine_id, device.trial_expires_at.isoformat(),
                "trial", secret)
            return {"status": "trial",
                    "expires_at": _iso(device.trial_expires_at),
                    "offline_token": token,
                    "trial_days_left": (device.trial_expires_at - now).days}
        return {"status": "expired", "pro": False,
                "detail": "Пробный период истёк — оформите подписку Pro"}

    # С ключом.
    lic = db.query(LicenseKey).filter_by(key=key.strip().upper()).first()
    if lic is None:
        return {"status": "invalid", "detail": "Неверный ключ активации"}
    existing = db.query(Activation).filter_by(
        key_id=lic.id, machine_id=machine_id).first()
    if existing is None:
        count = db.query(Activation).filter_by(key_id=lic.id).count()
        if count >= lic.max_devices:
            return {"status": "invalid",
                    "detail": f"Превышен лимит устройств для этого ключа "
                              f"({lic.max_devices})"}
        db.add(Activation(key_id=lic.id, machine_id=machine_id))
        db.commit()
    # Подписка по ключу: +365 дней от максимума(now, текущего конца).
    sub = db.query(Subscription).filter_by(
        machine_id=machine_id, status="active").first()
    base = now
    if sub and sub.current_period_end and sub.current_period_end > now:
        base = sub.current_period_end
    until = base + datetime.timedelta(days=365)
    if sub is None:
        sub = Subscription(machine_id=machine_id, tier="year",
                           status="active", current_period_end=until)
        db.add(sub)
    else:
        sub.current_period_end = until
        sub.tier = "year"
    db.commit()
    token = crypto.sign_token(machine_id, until.isoformat(), "pro", secret)
    return {"status": "active", "expires_at": _iso(until),
            "offline_token": token}


def validate(db, machine_id: str, secret: str) -> dict:
    """Энтайтлменты: pro, until, trial_days_left."""
    now = utcnow()
    sub = db.query(Subscription).filter_by(
        machine_id=machine_id, status="active").first()
    if sub and sub.current_period_end and sub.current_period_end > now:
        return {"pro": True, "until": _iso(sub.current_period_end),
                "trial_days_left": 0}
    device = db.query(Device).filter_by(machine_id=machine_id).first()
    if device and device.trial_expires_at and device.trial_expires_at > now:
        left = (device.trial_expires_at - now).days
        return {"pro": False, "until": _iso(device.trial_expires_at),
                "trial_days_left": max(left, 1)}
    return {"pro": False, "until": None, "trial_days_left": 0}


def extend_subscription(db, machine_id: str, days: int, tier: str = "month"):
    """Продление подписки (webhook invoice.paid)."""
    now = utcnow()
    sub = db.query(Subscription).filter_by(
        machine_id=machine_id, status="active").first()
    base = now
    if sub and sub.current_period_end and sub.current_period_end > now:
        base = sub.current_period_end
    until = base + datetime.timedelta(days=days)
    if sub is None:
        sub = Subscription(machine_id=machine_id, tier=tier,
                           status="active", current_period_end=until)
        db.add(sub)
    else:
        sub.current_period_end = until
        sub.tier = tier
    db.commit()
    return _iso(until)
