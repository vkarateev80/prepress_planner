# -*- coding: utf-8 -*-
"""Микросервис авторизации «Препресс-Планер».

Аккаунты email+пароль, HMAC-подписанные токены (общий секрет PP_AUTH_SECRET
с сервисом оплаты), пароли — pbkdf2_hmac с солью. Хранилище — SQLite.

API:
  POST /auth/register   {email, password}        → {token, user}
  POST /auth/login      {email, password}        → {token, user}
  POST /auth/logout     (Bearer token)           → {ok}
  GET  /auth/me         (Bearer token)           → {user}
  GET  /healthz                                   → {status, ...}

env:
  PP_AUTH_SECRET   — секрет подписи токенов (обязателен, ≥ 16 символов)
  PP_DATA_DIR      — каталог БД (по умолчанию <сервис>/data)
  PP_TOKEN_TTL     — срок токена, ч (по умолчанию 720 = 30 дней)
"""
import hashlib
import hmac
import json
import os
import secrets
import sqlite3
import threading
import time
from contextlib import asynccontextmanager
from pathlib import Path

from fastapi import Depends, FastAPI, Header, HTTPException
from pydantic import BaseModel, Field

BASE = Path(__file__).resolve().parent.parent
DATA = Path(os.environ.get("PP_DATA_DIR") or (BASE / "data"))
DATA.mkdir(parents=True, exist_ok=True)
DB_PATH = DATA / "auth.db"

SECRET = os.environ.get("PP_AUTH_SECRET", "").strip()
if len(SECRET) < 16:
    raise RuntimeError("PP_AUTH_SECRET обязателен (≥ 16 символов)")
TOKEN_TTL_H = float(os.environ.get("PP_TOKEN_TTL", "720").strip() or 720)
TOKEN_TTL_S = TOKEN_TTL_H * 3600

_db_lock = threading.Lock()

_EMAIL_RE = r"^[^@\s]+@[^@\s]+\.[^@\s]+$"


def _check_email(email: str):
    import re
    if not re.match(_EMAIL_RE, email):
        raise HTTPException(status_code=422, detail="Некорректный email")


def _connect() -> sqlite3.Connection:
    conn = sqlite3.connect(str(DB_PATH), check_same_thread=False)
    conn.row_factory = sqlite3.Row
    return conn


def _init_db():
    with _db_lock, _connect() as conn:
        conn.executescript(
            """
            CREATE TABLE IF NOT EXISTS users (
                id TEXT PRIMARY KEY,
                email TEXT NOT NULL UNIQUE,
                password_hash TEXT NOT NULL,
                created_at REAL NOT NULL
            );
            """
        )


# ---------- безопасность ----------

def _hash_password(password: str) -> str:
    salt = secrets.token_hex(16)
    digest = hashlib.pbkdf2_hmac(
        "sha256", password.encode("utf-8"), bytes.fromhex(salt), 200_000)
    return f"{salt}${digest.hex()}"


def _verify_password(password: str, stored: str) -> bool:
    try:
        salt, digest_hex = stored.split("$", 1)
    except ValueError:
        return False
    digest = hashlib.pbkdf2_hmac(
        "sha256", password.encode("utf-8"), bytes.fromhex(salt), 200_000)
    return hmac.compare_digest(digest.hex(), digest_hex)


def _sign_token(user_id: str, email: str) -> str:
    payload = {
        "sub": user_id,
        "email": email,
        "exp": int(time.time()) + int(TOKEN_TTL_S),
    }
    body = json.dumps(payload, separators=(",", ":")).encode()
    sig = hmac.new(SECRET.encode(), body, hashlib.sha256).hexdigest()
    return f"{sig}.{body.decode()}"


def verify_token(token: str) -> dict:
    """Проверка подписи токена (используется и сервисом оплаты)."""
    try:
        sig, body = token.split(".", 1)
        expect = hmac.new(SECRET.encode(), body.encode(),
                          hashlib.sha256).hexdigest()
        if not hmac.compare_digest(sig, expect):
            raise ValueError("bad signature")
        payload = json.loads(body)
        if int(payload.get("exp", 0)) < int(time.time()):
            raise ValueError("expired")
        return {"sub": payload["sub"], "email": payload["email"]}
    except Exception as e:  # noqa: BLE001
        raise ValueError(f"недействительный токен: {e}")


# ---------- модели ----------

class RegisterIn(BaseModel):
    email: str = Field(min_length=3, max_length=254)
    password: str = Field(min_length=6, max_length=128)


class LoginIn(BaseModel):
    email: str = Field(min_length=3, max_length=254)
    password: str = Field(min_length=1, max_length=128)


def _user_row(row) -> dict:
    return {"id": row["id"], "email": row["email"],
            "created_at": row["created_at"]}


# ---------- app ----------

@asynccontextmanager
async def _lifespan(app: FastAPI):
    _init_db()
    yield


app = FastAPI(title="Препресс-Планер: авторизация", version="0.1.0",
              lifespan=_lifespan)

# Таблицы создаём сразу при импорте (TestClient вне контекста lifespan не
# вызывает startup; конвертер делает так же через mkdir на импорте).
_init_db()


def _auth_dep(authorization: str | None = Header(default=None)) -> dict:
    if not authorization or not authorization.startswith("Bearer "):
        raise HTTPException(status_code=401, detail="Требуется токен")
    try:
        return verify_token(authorization[7:].strip())
    except ValueError as e:
        raise HTTPException(status_code=401, detail=str(e))


@app.post("/auth/register")
def register(body: RegisterIn):
    email = body.email.lower().strip()
    _check_email(email)
    with _db_lock, _connect() as conn:
        existing = conn.execute(
            "SELECT id FROM users WHERE email = ?", (email,)).fetchone()
        if existing is not None:
            raise HTTPException(status_code=409, detail="Email уже зарегистрирован")
        user_id = secrets.token_hex(16)
        conn.execute(
            "INSERT INTO users (id, email, password_hash, created_at) "
            "VALUES (?, ?, ?, ?)",
            (user_id, email, _hash_password(body.password), time.time()))
    token = _sign_token(user_id, email)
    return {"token": token, "user": {"id": user_id, "email": email}}


@app.post("/auth/login")
def login(body: LoginIn):
    email = body.email.lower().strip()
    _check_email(email)
    with _db_lock, _connect() as conn:
        row = conn.execute(
            "SELECT * FROM users WHERE email = ?", (email,)).fetchone()
        if row is None or not _verify_password(body.password, row["password_hash"]):
            raise HTTPException(status_code=401, detail="Неверный email или пароль")
    token = _sign_token(row["id"], email)
    return {"token": token, "user": _user_row(row)}


@app.post("/auth/logout")
def logout(user: dict = Depends(_auth_dep)):
    # Токены stateless (HMAC); «выход» на клиенте — удаление токена.
    return {"ok": True, "user_id": user["sub"]}


@app.get("/auth/me")
def me(user: dict = Depends(_auth_dep)):
    return {"user": user}


@app.get("/healthz")
def healthz():
    return {"status": "ok", "service": "auth",
            "db": str(DB_PATH), "token_ttl_h": TOKEN_TTL_H}
