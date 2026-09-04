# -*- coding: utf-8 -*-
"""Микросервис авторизации «Препресс-Планер».

Аккаунты email+пароль. Сессии — СЕРВЕРНЫЕ (таблица sessions, opaque-токены,
хранится только sha256 токена): выход реально отзывает сессию, лимит устройств
1/1 — новый вход с другого device_id вытесняет старую сессию. Payments
проверяет токены внутренним вызовом POST /auth/verify (env PP_AUTH_URL).

«Забыли пароль»: POST /auth/forgot создаёт одноразовый код (TTL 30 мин) и
отправляет по email через SMTP; если SMTP не настроен (dev) — код возвращается
в ответе. POST /auth/reset меняет пароль и отзывает все сессии.

API:
  POST /auth/register  {email, password, device_id}          → {token, user}
  POST /auth/login     {email, password, device_id}          → {token, user}
  POST /auth/logout    (Bearer)                              → {ok}
  GET  /auth/me        (Bearer)                              → {user}
  GET  /auth/devices   (Bearer)                              → {devices, current}
  POST /auth/verify    (Bearer) — внутренний вызов payments  → {sub, email}
  POST /auth/forgot    {email}                               → {ok, dev_code?}
  POST /auth/reset     {email, code, new_password}           → {ok}
  GET  /healthz

env:
  PP_AUTH_SECRET   — не используется для подписи (совместимость), ≥16
  PP_DATA_DIR      — каталог БД
  PP_TOKEN_TTL     — срок сессии, ч (по умолчанию 720 = 30 дней)
  PP_RESET_TTL     — срок кода сброса, мин (по умолчанию 30)
  PP_SMTP_HOST/PORT/USER/PASSWORD/FROM — почта для сброса (STARTTLS 587)
  PP_SMTP_SSL      — 1 = сразу TLS (465)
"""
import hashlib
import os
import secrets
import smtplib
import sqlite3
import threading
import time
from contextlib import asynccontextmanager
from email.mime.text import MIMEText
from pathlib import Path
from string import digits

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
TOKEN_TTL_S = int(TOKEN_TTL_H * 3600)
RESET_TTL_MIN = float(os.environ.get("PP_RESET_TTL", "30").strip() or 30)
RESET_TTL_S = int(RESET_TTL_MIN * 60)
RESET_CODE_LEN = 6

_db_lock = threading.RLock()  # RLock: вложенные обращения (reset → use_code)

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
            CREATE TABLE IF NOT EXISTS sessions (
                token_hash TEXT PRIMARY KEY,
                user_id TEXT NOT NULL,
                device_id TEXT NOT NULL,
                created_at REAL NOT NULL,
                expires_at REAL NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_sessions_user
                ON sessions(user_id);
            CREATE TABLE IF NOT EXISTS reset_codes (
                email TEXT NOT NULL,
                code_hash TEXT NOT NULL,
                created_at REAL NOT NULL,
                expires_at REAL NOT NULL,
                used INTEGER NOT NULL DEFAULT 0
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
    import hmac
    return hmac.compare_digest(digest.hex(), digest_hex)


def _sha256(s: str) -> str:
    return hashlib.sha256(s.encode("utf-8")).hexdigest()


def _new_token() -> str:
    return secrets.token_urlsafe(32)


def _issue_session(conn, user_id: str, email: str, device_id: str) -> str:
    """Политика 1/1: отзываем все прежние сессии пользователя и выдаём новую.

    Возвращает токен (клиенту); в БД — только его sha256.
    """
    now = time.time()
    conn.execute("DELETE FROM sessions WHERE user_id = ?", (user_id,))
    token = _new_token()
    conn.execute(
        "INSERT INTO sessions (token_hash, user_id, device_id, "
        "created_at, expires_at) VALUES (?, ?, ?, ?, ?)",
        (_sha256(token), user_id, device_id, now, now + TOKEN_TTL_S))
    return token


def _session_claims(token: str) -> dict:
    """Проверка токена: возвращает {sub, email, device_id} или бросает."""
    if not token:
        raise ValueError("пустой токен")
    with _db_lock, _connect() as conn:
        row = conn.execute(
            "SELECT s.token_hash, s.device_id, s.expires_at, u.id, u.email "
            "FROM sessions s JOIN users u ON u.id = s.user_id "
            "WHERE s.token_hash = ?", (_sha256(token),)).fetchone()
    if row is None:
        raise ValueError("сессия не найдена")
    if row["expires_at"] < time.time():
        raise ValueError("сессия истекла")
    return {"sub": row["id"], "email": row["email"],
            "device_id": row["device_id"]}


# ---------- почта (сброс пароля) ----------

def _smtp_config() -> dict | None:
    host = os.environ.get("PP_SMTP_HOST", "").strip()
    if not host:
        return None
    return {
        "host": host,
        "port": int(os.environ.get("PP_SMTP_PORT", "587").strip() or 587),
        "user": os.environ.get("PP_SMTP_USER", "").strip(),
        "password": os.environ.get("PP_SMTP_PASSWORD", "").strip(),
        "from": os.environ.get("PP_SMTP_FROM", "").strip() or host,
        "ssl": os.environ.get("PP_SMTP_SSL", "").strip() == "1",
    }


def _send_email(to: str, subject: str, text: str) -> None:
    cfg = _smtp_config()
    if cfg is None:
        raise RuntimeError("SMTP не настроен (PP_SMTP_HOST)")
    msg = MIMEText(text, "plain", "utf-8")
    msg["Subject"] = subject
    msg["From"] = cfg["from"]
    msg["To"] = to
    if cfg["ssl"]:
        server = smtplib.SMTP_SSL(cfg["host"], cfg["port"], timeout=15)
    else:
        server = smtplib.SMTP(cfg["host"], cfg["port"], timeout=15)
        server.starttls()
    try:
        if cfg["user"]:
            server.login(cfg["user"], cfg["password"])
        server.sendmail(cfg["from"], [to], msg.as_string())
    finally:
        try:
            server.quit()
        except Exception:
            pass


def _new_reset_code(email: str) -> str:
    code = "".join(secrets.choice(digits) for _ in range(RESET_CODE_LEN))
    now = time.time()
    with _db_lock, _connect() as conn:
        conn.execute("DELETE FROM reset_codes WHERE email = ?", (email,))
        conn.execute(
            "INSERT INTO reset_codes (email, code_hash, created_at, "
            "expires_at, used) VALUES (?, ?, ?, ?, 0)",
            (email, _sha256(code), now, now + RESET_TTL_S))
    return code


def _use_reset_code(email: str, code: str) -> bool:
    now = time.time()
    with _db_lock, _connect() as conn:
        row = conn.execute(
            "SELECT code_hash, expires_at, used FROM reset_codes "
            "WHERE email = ? ORDER BY created_at DESC LIMIT 1",
            (email,)).fetchone()
        if row is None or row["used"] or row["expires_at"] < now:
            return False
        import hmac
        if not hmac.compare_digest(row["code_hash"], _sha256(code)):
            return False
        conn.execute(
            "UPDATE reset_codes SET used = 1 WHERE email = ?", (email,))
        return True


# ---------- модели ----------

class RegisterIn(BaseModel):
    email: str = Field(min_length=3, max_length=254)
    password: str = Field(min_length=6, max_length=128)
    device_id: str = Field(min_length=1, max_length=128)


class LoginIn(BaseModel):
    email: str = Field(min_length=3, max_length=254)
    password: str = Field(min_length=1, max_length=128)
    device_id: str = Field(min_length=1, max_length=128)


class ForgotIn(BaseModel):
    email: str = Field(min_length=3, max_length=254)


class ResetIn(BaseModel):
    email: str = Field(min_length=3, max_length=254)
    code: str = Field(min_length=RESET_CODE_LEN,
                      max_length=RESET_CODE_LEN)
    new_password: str = Field(min_length=6, max_length=128)


def _user_row(row) -> dict:
    return {"id": row["id"], "email": row["email"],
            "created_at": row["created_at"]}


# ---------- app ----------

@asynccontextmanager
async def _lifespan(app: FastAPI):
    _init_db()
    yield


app = FastAPI(title="Препресс-Планер: авторизация", version="0.2.0",
              lifespan=_lifespan)

_init_db()


def _auth_dep(authorization: str | None = Header(default=None)) -> dict:
    if not authorization or not authorization.startswith("Bearer "):
        raise HTTPException(status_code=401, detail="Требуется токен")
    try:
        return _session_claims(authorization[7:].strip())
    except ValueError as e:
        raise HTTPException(status_code=401, detail=str(e))


def _create_user(conn, email: str, password: str) -> str:
    user_id = secrets.token_hex(16)
    conn.execute(
        "INSERT INTO users (id, email, password_hash, created_at) "
        "VALUES (?, ?, ?, ?)",
        (user_id, email, _hash_password(password), time.time()))
    return user_id


@app.post("/auth/register")
def register(body: RegisterIn):
    email = body.email.lower().strip()
    _check_email(email)
    with _db_lock, _connect() as conn:
        existing = conn.execute(
            "SELECT id FROM users WHERE email = ?", (email,)).fetchone()
        if existing is not None:
            raise HTTPException(status_code=409,
                                detail="Email уже зарегистрирован")
        user_id = _create_user(conn, email, body.password)
        token = _issue_session(conn, user_id, email, body.device_id)
        row = conn.execute(
            "SELECT * FROM users WHERE id = ?", (user_id,)).fetchone()
    return {"token": token, "user": _user_row(row)}


@app.post("/auth/login")
def login(body: LoginIn):
    email = body.email.lower().strip()
    _check_email(email)
    with _db_lock, _connect() as conn:
        row = conn.execute(
            "SELECT * FROM users WHERE email = ?", (email,)).fetchone()
        if row is None or not _verify_password(body.password,
                                               row["password_hash"]):
            raise HTTPException(status_code=401,
                                detail="Неверный email или пароль")
        # 1/1: старые сессии удаляются при выдаче новой.
        token = _issue_session(conn, row["id"], email, body.device_id)
    return {"token": token, "user": _user_row(row)}


@app.post("/auth/logout")
def logout(user: dict = Depends(_auth_dep),
           authorization: str | None = Header(default=None)):
    # Серверные сессии: удаляем именно эту.
    token = authorization[7:].strip() if authorization else ""
    with _db_lock, _connect() as conn:
        conn.execute(
            "DELETE FROM sessions WHERE token_hash = ?", (_sha256(token),))
    return {"ok": True, "user_id": user["sub"]}


@app.get("/auth/me")
def me(user: dict = Depends(_auth_dep)):
    return {"user": user}


@app.get("/auth/devices")
def devices(user: dict = Depends(_auth_dep),
            authorization: str | None = Header(default=None)):
    """Список активных устройств (при лимите 1/1 — максимум одно)."""
    token = authorization[7:].strip() if authorization else ""
    with _db_lock, _connect() as conn:
        rows = conn.execute(
            "SELECT token_hash, device_id, created_at, expires_at "
            "FROM sessions "
            "WHERE user_id = ? AND expires_at > ? ORDER BY created_at DESC",
            (user["sub"], time.time())).fetchall()
    current_hash = _sha256(token)
    items = [{
        "device_id": r["device_id"],
        "current": r["token_hash"] == current_hash,
        "created_at": r["created_at"],
        "expires_at": r["expires_at"],
    } for r in rows]
    return {"devices": items, "limit": 1}


@app.post("/auth/verify")
def verify(authorization: str | None = Header(default=None)):
    """Внутренний вызов (payments): токен → {sub, email}."""
    if not authorization or not authorization.startswith("Bearer "):
        raise HTTPException(status_code=401, detail="Требуется токен")
    try:
        claims = _session_claims(authorization[7:].strip())
    except ValueError as e:
        raise HTTPException(status_code=401, detail=str(e))
    return {"sub": claims["sub"], "email": claims["email"]}


@app.post("/auth/forgot")
def forgot(body: ForgotIn):
    """Запрос сброса: код по email (SMTP) или в ответе (dev без SMTP)."""
    email = body.email.lower().strip()
    _check_email(email)
    with _db_lock, _connect() as conn:
        row = conn.execute(
            "SELECT id FROM users WHERE email = ?", (email,)).fetchone()
    # Пользователь может не существовать — но не раскрываем: всегда ok.
    code = _new_reset_code(email)
    smtp = _smtp_config()
    if smtp is None:
        # Dev-режим: кода нет в почте — возвращаем в ответе.
        if row is None:
            return {"ok": True, "dev_code": code, "dev_hint": "email не найден"}
        return {"ok": True, "dev_code": code}
    try:
        _send_email(
            email,
            "Сброс пароля — Препресс-Планер",
            f"Код для сброса пароля: {code}\n"
            f"Код действителен {int(RESET_TTL_MIN)} минут.")
    except Exception:
        # Почта недоступна — в dev-логах возвращаем код, чтобы не терять.
        return {"ok": True, "dev_code": code}
    return {"ok": True}


@app.post("/auth/reset")
def reset(body: ResetIn):
    email = body.email.lower().strip()
    _check_email(email)
    with _db_lock, _connect() as conn:
        row = conn.execute(
            "SELECT id FROM users WHERE email = ?", (email,)).fetchone()
        if row is None:
            raise HTTPException(status_code=404,
                                detail="Пользователь не найден")
        if not _use_reset_code(email, body.code):
            raise HTTPException(status_code=400,
                                detail="Неверный или истёкший код")
        conn.execute(
            "UPDATE users SET password_hash = ? WHERE id = ?",
            (_hash_password(body.new_password), row["id"]))
        conn.execute(
            "DELETE FROM sessions WHERE user_id = ?", (row["id"],))
    return {"ok": True}


@app.get("/healthz")
def healthz():
    smtp = _smtp_config()
    return {"status": "ok", "service": "auth", "db": str(DB_PATH),
            "sessions": "server-side", "device_limit": 1,
            "smtp": bool(smtp), "reset_ttl_min": RESET_TTL_MIN}
