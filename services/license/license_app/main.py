# -*- coding: utf-8 -*-
"""FastAPI лицензионного сервера: /license/*, /webhooks/*, /admin/*."""
import os
from pathlib import Path

from fastapi import Depends, FastAPI, HTTPException
from pydantic import BaseModel
from sqlalchemy.orm import Session

from . import crypto, licensing
from .models import LicenseKey, make_engine, make_session

BASE = Path(__file__).resolve().parent.parent
DB_URL = os.environ.get("PP_LICENSE_DB", f"sqlite:///{BASE / 'license.db'}")
engine = make_engine(DB_URL)

app = FastAPI(title="Препресс-Планер: лицензии", version="0.1.0")


def get_db():
    db = make_session(engine)
    try:
        yield db
    finally:
        db.close()


class ActivateIn(BaseModel):
    machine_id: str
    key: str | None = None


class ValidateIn(BaseModel):
    machine_id: str


class WebhookStripe(BaseModel):
    event: str  # invoice.paid | ...
    machine_id: str
    period_days: int = 30


class AppleReceipt(BaseModel):
    receipt: str = ""


class AdminKeyIn(BaseModel):
    key: str | None = None
    max_devices: int = 3


@app.post("/license/activate")
def activate(body: ActivateIn, db: Session = Depends(get_db)):
    if not body.machine_id or len(body.machine_id) < 6:
        raise HTTPException(status_code=422, detail="machine_id обязателен")
    return licensing.activate(db, body.machine_id, body.key,
                              crypto.signing_secret())


@app.post("/license/validate")
def validate(body: ValidateIn, db: Session = Depends(get_db)):
    if not body.machine_id:
        raise HTTPException(status_code=422, detail="machine_id обязателен")
    return licensing.validate(db, body.machine_id, crypto.signing_secret())


@app.get("/license/entitlements/{machine_id}")
def entitlements(machine_id: str, db: Session = Depends(get_db)):
    return licensing.validate(db, machine_id, crypto.signing_secret())


@app.post("/webhooks/stripe")
def stripe_webhook(body: WebhookStripe, db: Session = Depends(get_db)):
    if body.event == "invoice.paid":
        until = licensing.extend_subscription(
            db, body.machine_id, body.period_days, "month")
        return {"ok": True, "until": until}
    return {"ok": True, "event": body.event, "handled": False}


@app.post("/webhooks/apple")
def apple_webhook(body: AppleReceipt, db: Session = Depends(get_db)):
    # Реальная валидация ресивера (App Store Server API) — вне scope MVP;
    # структура для клиента (аг.12). Принимаем и возвращаем ok.
    return {"ok": True, "detail": "Ресивер принят (валидация — в проде)"}


@app.get("/admin/keys")
def list_keys(db: Session = Depends(get_db)):
    keys = db.query(LicenseKey).all()
    return [{"key": k.key, "max_devices": k.max_devices,
             "created_at": k.created_at.isoformat()} for k in keys]


@app.post("/admin/keys")
def create_key(body: AdminKeyIn, db: Session = Depends(get_db)):
    key = (body.key or crypto.generate_key()).upper()
    lic = LicenseKey(key=key, max_devices=body.max_devices)
    db.add(lic)
    db.commit()
    return {"key": key, "max_devices": body.max_devices}


@app.get("/health")
def health():
    return {"ok": True}
