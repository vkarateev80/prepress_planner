# -*- coding: utf-8 -*-
"""Тесты лицензионного сервера: триал 15 дней, ключи, токены, webhooks."""
import base64
import datetime
import json
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]  # services/license
sys.path.insert(0, str(ROOT))

import license_app.models as models  # noqa: E402

_FAKE_NOW: datetime.datetime | None = None


def _fake_utcnow() -> datetime.datetime:
    if _FAKE_NOW is not None:
        return _FAKE_NOW
    return datetime.datetime(2026, 1, 1)


models.utcnow = _fake_utcnow

from sqlalchemy import create_engine  # noqa: E402
from sqlalchemy.orm import sessionmaker  # noqa: E402

from license_app import crypto, licensing  # noqa: E402

SECRET = "test-secret"


@pytest.fixture()
def db():
    eng = create_engine("sqlite://", connect_args={"check_same_thread": False})
    models.Base.metadata.create_all(eng)
    session = sessionmaker(bind=eng)()
    yield session
    session.close()


def _set_now(dt: datetime.datetime):
    global _FAKE_NOW
    _FAKE_NOW = dt


@pytest.fixture(autouse=True)
def reset_time():
    global _FAKE_NOW
    _FAKE_NOW = datetime.datetime(2026, 1, 1)
    yield
    _FAKE_NOW = None


def test_activate_trial_15_days(db):
    res = licensing.activate(db, "machine-1", None, SECRET)
    assert res["status"] == "trial"
    until = datetime.datetime.fromisoformat(res["expires_at"])
    assert until == datetime.datetime(2026, 1, 16)
    assert res["offline_token"]


def test_activate_trial_not_reset_on_repeat(db):
    licensing.activate(db, "m2", None, SECRET)
    _set_now(datetime.datetime(2026, 1, 10))
    res = licensing.activate(db, "m2", None, SECRET)
    assert res["status"] == "trial"
    assert res["trial_days_left"] == 6  # до 16 янв = 6 дней


def test_activate_after_expiry(db):
    licensing.activate(db, "m3", None, SECRET)
    _set_now(datetime.datetime(2026, 2, 1))
    res = licensing.activate(db, "m3", None, SECRET)
    assert res["status"] == "expired"
    assert res["pro"] is False


def test_activate_with_key_and_device_limit(db):
    key = crypto.generate_key()
    db.add(models.LicenseKey(key=key, max_devices=3))
    db.commit()
    for i in range(3):
        res = licensing.activate(db, f"dev-{i}", key, SECRET)
        assert res["status"] == "active", res
    res4 = licensing.activate(db, "dev-4", key, SECRET)
    assert res4["status"] == "invalid"
    assert "лимит" in res4["detail"], res4["detail"]


def test_invalid_key(db):
    res = licensing.activate(db, "dev-x", "XXXX-XXXX-XXXX-XXXX", SECRET)
    assert res["status"] == "invalid"
    assert "Неверный ключ" in res["detail"], res["detail"]


def test_validate_trial_and_subscription(db):
    licensing.activate(db, "v1", None, SECRET)
    v = licensing.validate(db, "v1", SECRET)
    assert v["pro"] is False
    assert v["trial_days_left"] > 0

    until = datetime.datetime(2026, 6, 1)
    db.add(models.Subscription(
        machine_id="v1", tier="year", status="active",
        current_period_end=until))
    db.commit()
    v2 = licensing.validate(db, "v1", SECRET)
    assert v2["pro"] is True


def test_crypto_token_tamper(db):
    until = datetime.datetime(2026, 6, 1).isoformat()
    token = crypto.sign_token("m", until, "pro", SECRET)
    assert crypto.verify_token(token, SECRET) is not None
    # Изменённый machine_id -> подпись не сходится.
    body, sig = token.split(".")
    payload = json.loads(
        base64.urlsafe_b64decode(body + "=" * (-len(body) % 4)).decode())
    payload["machine_id"] = "other"
    raw = json.dumps(payload, separators=(",", ":"))
    new_body = base64.urlsafe_b64encode(raw.encode()).rstrip(b"=").decode()
    assert crypto.verify_token(f"{new_body}.{sig}", SECRET) is None
    # Неверный секрет.
    assert crypto.verify_token(token, "other-secret") is None


def test_token_expired(db):
    # Токен с until в прошлом -> невалиден.
    past = datetime.datetime(2025, 1, 1).isoformat()
    token = crypto.sign_token("m", past, "pro", SECRET)
    assert crypto.verify_token(token, SECRET) is None


def test_webhook_stripe_extend(db):
    until1 = licensing.extend_subscription(db, "w1", 30, "month")
    assert until1 is not None
    v = licensing.validate(db, "w1", SECRET)
    assert v["pro"] is True
    until2 = licensing.extend_subscription(db, "w1", 30, "month")
    assert until2 > until1


def test_key_format():
    k = crypto.generate_key()
    parts = k.split("-")
    assert len(parts) == 4
    assert all(len(p) == 4 for p in parts)
