# -*- coding: utf-8 -*-
"""Микросервис авторизации «Препресс-Планер» (SaaS, self-hosted).

Основание: PRD v2 (F-19) и System Design v1 (ADR-4, §12.2, §13.1).

Аккаунты email+пароль, СЕРВЕРНЫЕ сессии (таблица sessions, opaque-токены,
в БД — только sha256), отзыв сессии реально работает. Мультитенантность:
организации и членство с ролями (owner/admin/member/viewer). Лимит устройств
1/1 и вытеснение сессии по device_id УДАЛЕНЫ: пользователь может иметь
несколько активных сессий (браузер + десктоп-совместимость).

Legacy `services/license` (machine-id, офлайн-токены) в SaaS-пути не
используется — auth его не вызывает и о нём не знает. Внутренние сервисы
(billing/api) проверяют токен вызовом POST /auth/verify и получают
{sub, email, orgs:[{org_id, role}]}.

Пароли: pbkdf2_hmac sha256, 200 000 итераций, соль secrets.token_hex(16),
хранимый формат `salt$digest_hex` (инвариант N-5 — без изменений).

«Забыли пароль»: POST /auth/forgot создаёт одноразовый 6-значный код
(TTL 30 мин, в БД только sha256) и отправляет его по SMTP. Код НИКОГДА не
возвращается в ответе (в т.ч. в dev-режиме без SMTP) и не раскрывается факт
существования email. POST /auth/reset меняет пароль и отзывает все сессии.

Зависимости: стандартная библиотека Python + fastapi/pydantic (+uvicorn для
запуска). Почта — smtplib/email из stdlib. Внешних пакетов для логики нет.

API:
  POST /auth/register          {email, password, org_name?}  → 201 {token, user, orgs}
  POST /auth/login             {email, password, device_id?} → {token, user, orgs}
  POST /auth/logout            (Bearer)                      → {ok, user_id}
  GET  /auth/me                (Bearer)                      → {user, orgs, memberships}
  GET  /auth/sessions          (Bearer)                      → {sessions:[{id,...,current}]}
  POST /auth/sessions/{id}/revoke (Bearer)                   → {ok}
  GET  /auth/devices           (Bearer) — совместимость      → {devices, current}
  GET  /auth/orgs              (Bearer)                      → {orgs:[{org_id,name,role}]}
  POST /auth/orgs              (Bearer) {name}               → {org_id, name, role}
  POST /auth/verify            (Bearer) — внутренний вызов  → {sub, email, orgs}
  POST /auth/forgot            {email}                       → {ok: true}
  POST /auth/reset             {email, code, new_password}   → {ok: true}
  GET  /auth/orgs/{id}/members (Bearer, член org)            → {members:[...]}
  POST /auth/orgs/{id}/members (Bearer, owner/admin) {email, role?}
                                                             → 201 added|invited
  POST /auth/orgs/{id}/invites/accept (Bearer) {code}        → {ok, org_id, role}
  DELETE /auth/orgs/{id}/members/{user_id} (Bearer, owner/admin) → {ok}
  GET  /healthz

env:
  PP_AUTH_SECRET   — обязательный секрет (≥16 символов), legacy-совместимость
  PP_DATA_DIR      — каталог БД (auth.db)
  PP_TOKEN_TTL     — срок сессии, ч (по умолчанию 720 = 30 дней)
  PP_RESET_TTL     — срок кода сброса, мин (по умолчанию 30)
  PP_DEFAULT_ORG   — 1 (по умолчанию) = регистрация без org_name создаёт
                     личную организацию; 0 = пользователь без организации
  PP_SMTP_HOST/PORT/USER/PASSWORD/FROM — почта для сброса (STARTTLS 587)
  PP_SMTP_SSL      — 1 = сразу TLS (465)
"""
import hashlib
import hmac
import os
import re
import secrets
import smtplib
import sqlite3
import threading
import time
from contextlib import asynccontextmanager
from email.mime.text import MIMEText
from pathlib import Path
from string import digits
from typing import Optional

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
INVITE_TTL_S = 7 * 86400  # приглашения в организацию: 7 дней (F-19)
# Регистрация без org_name: 1 — создаём личную организацию (по умолчанию),
# 0 — пользователь без организации (memberships добавляются позже).
DEFAULT_ORG = os.environ.get("PP_DEFAULT_ORG", "1").strip() != "0"

ROLES = ("owner", "admin", "member", "viewer")
ADMIN_ROLES = ("owner", "admin")

_db_lock = threading.RLock()  # RLock: вложенные обращения (reset → use_code)

_EMAIL_RE = r"^[^@\s]+@[^@\s]+\.[^@\s]+$"


def _check_email(email: str):
    if not re.match(_EMAIL_RE, email):
        raise HTTPException(status_code=422, detail="Некорректный email")


def _connect() -> sqlite3.Connection:
    conn = sqlite3.connect(str(DB_PATH), check_same_thread=False)
    conn.row_factory = sqlite3.Row
    return conn


def _columns(conn, table: str) -> set:
    rows = conn.execute(f"PRAGMA table_info({table})").fetchall()
    return {r["name"] for r in rows}


def _table_exists(conn, table: str) -> bool:
    row = conn.execute(
        "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?",
        (table,)).fetchone()
    return row is not None


def _init_db():
    """Создание схемы + безопасная миграция legacy-БД (данные сохраняются).

    Legacy (v0.2): sessions(token_hash, user_id, device_id, created_at,
    expires_at), reset_codes(email, code_hash, created_at, expires_at, used).
    Новая модель: organizations, memberships, sessions(+meta/revoked_at),
    reset_codes(+user_id).
    """
    with _db_lock, _connect() as conn:
        conn.executescript(
            """
            CREATE TABLE IF NOT EXISTS users (
                id TEXT PRIMARY KEY,
                email TEXT NOT NULL UNIQUE,
                password_hash TEXT NOT NULL,
                created_at REAL NOT NULL,
                updated_at REAL
            );
            CREATE TABLE IF NOT EXISTS organizations (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                created_by TEXT,
                created_at REAL NOT NULL,
                updated_at REAL
            );
            CREATE TABLE IF NOT EXISTS memberships (
                id TEXT PRIMARY KEY,
                org_id TEXT NOT NULL,
                user_id TEXT NOT NULL,
                role TEXT NOT NULL,
                invited_by TEXT,
                created_at REAL NOT NULL,
                UNIQUE (org_id, user_id)
            );
            CREATE INDEX IF NOT EXISTS idx_memberships_user
                ON memberships(user_id);
            CREATE INDEX IF NOT EXISTS idx_memberships_org
                ON memberships(org_id);
            CREATE TABLE IF NOT EXISTS sessions (
                token_hash TEXT PRIMARY KEY,
                user_id TEXT NOT NULL,
                device_id TEXT,
                created_at REAL NOT NULL,
                expires_at REAL NOT NULL,
                revoked_at REAL,
                meta TEXT
            );
            CREATE INDEX IF NOT EXISTS idx_sessions_user
                ON sessions(user_id);
            CREATE TABLE IF NOT EXISTS reset_codes (
                email TEXT NOT NULL,
                user_id TEXT,
                code_hash TEXT NOT NULL,
                created_at REAL NOT NULL,
                expires_at REAL NOT NULL,
                used INTEGER NOT NULL DEFAULT 0
            );
            CREATE INDEX IF NOT EXISTS idx_reset_codes_email
                ON reset_codes(email);
            CREATE TABLE IF NOT EXISTS invites (
                id TEXT PRIMARY KEY,
                org_id TEXT NOT NULL,
                email TEXT NOT NULL,
                role TEXT NOT NULL,
                code_hash TEXT NOT NULL,
                invited_by TEXT,
                created_at REAL NOT NULL,
                expires_at REAL NOT NULL,
                accepted_at REAL
            );
            CREATE INDEX IF NOT EXISTS idx_invites_email
                ON invites(email);
            """
        )
        # --- миграция legacy → новая схема (идемпотентно) ---
        user_cols = _columns(conn, "users")
        if "updated_at" not in user_cols:
            conn.execute("ALTER TABLE users ADD COLUMN updated_at REAL")
        ses_cols = _columns(conn, "sessions")
        if "revoked_at" not in ses_cols:
            conn.execute("ALTER TABLE sessions ADD COLUMN revoked_at REAL")
        if "meta" not in ses_cols:
            conn.execute("ALTER TABLE sessions ADD COLUMN meta TEXT")
        if "device_id" in ses_cols:
            # device_id больше не обязателен: legacy NOT NULL снимаем
            # пересозданием таблицы с сохранением строк.
            not_null = {r["name"]: r["notnull"]
                        for r in conn.execute(
                            "PRAGMA table_info(sessions)").fetchall()}
            if not_null.get("device_id"):
                conn.executescript(
                    """
                    ALTER TABLE sessions RENAME TO sessions_legacy;
                    CREATE TABLE sessions (
                        token_hash TEXT PRIMARY KEY,
                        user_id TEXT NOT NULL,
                        device_id TEXT,
                        created_at REAL NOT NULL,
                        expires_at REAL NOT NULL,
                        revoked_at REAL,
                        meta TEXT
                    );
                    INSERT INTO sessions (token_hash, user_id, device_id,
                        created_at, expires_at, revoked_at, meta)
                        SELECT token_hash, user_id, device_id, created_at,
                               expires_at, revoked_at, meta
                        FROM sessions_legacy;
                    DROP TABLE sessions_legacy;
                    CREATE INDEX IF NOT EXISTS idx_sessions_user
                        ON sessions(user_id);
                    """
                )
        rc_cols = _columns(conn, "reset_codes")
        if "user_id" not in rc_cols:
            conn.execute("ALTER TABLE reset_codes ADD COLUMN user_id TEXT")
        # Backfill: связываем legacy-коды с пользователями по email.
        conn.execute(
            "UPDATE reset_codes SET user_id = ("
            "  SELECT u.id FROM users u WHERE u.email = reset_codes.email) "
            "WHERE user_id IS NULL")


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


def _sha256(s: str) -> str:
    return hashlib.sha256(s.encode("utf-8")).hexdigest()


def _new_token() -> str:
    return secrets.token_urlsafe(32)


def _issue_session(conn, user_id: str, device_id: Optional[str] = None) -> str:
    """Выдаёт новую сессию, НЕ затрагивая прежние (политика 1/1 удалена).

    Возвращает токен (клиенту); в БД — только его sha256.
    """
    now = time.time()
    token = _new_token()
    conn.execute(
        "INSERT INTO sessions (token_hash, user_id, device_id, created_at, "
        "expires_at, revoked_at, meta) VALUES (?, ?, ?, ?, ?, NULL, NULL)",
        (_sha256(token), user_id, device_id, now, now + TOKEN_TTL_S))
    return token


def _session_claims(token: str) -> dict:
    """Проверка токена: {sub, email, device_id, session_id} или ValueError.

    Истёкшие/отозванные токены отклоняются. Просроченные сессии подчищаются.
    """
    if not token:
        raise ValueError("пустой токен")
    token_hash = _sha256(token)
    now = time.time()
    with _db_lock, _connect() as conn:
        row = conn.execute(
            "SELECT s.token_hash, s.device_id, s.created_at, s.expires_at, "
            "s.revoked_at, u.id, u.email "
            "FROM sessions s JOIN users u ON u.id = s.user_id "
            "WHERE s.token_hash = ?", (token_hash,)).fetchone()
        conn.execute(
            "DELETE FROM sessions WHERE expires_at < ? AND revoked_at IS NULL",
            (now,))
    if row is None:
        raise ValueError("сессия не найдена")
    if row["expires_at"] < now:
        raise ValueError("сессия истекла")
    if row["revoked_at"] is not None:
        raise ValueError("сессия отозвана")
    return {"sub": row["id"], "email": row["email"],
            "device_id": row["device_id"], "session_id": row["token_hash"]}


# ---------- организации / членство ----------

def _orgs_of(conn, user_id: str) -> list:
    """Организации пользователя с ролями: [{org_id, name, role}]."""
    rows = conn.execute(
        "SELECT m.org_id, m.role, o.name FROM memberships m "
        "LEFT JOIN organizations o ON o.id = m.org_id "
        "WHERE m.user_id = ? ORDER BY m.created_at ASC", (user_id,)).fetchall()
    return [{"org_id": r["org_id"], "name": r["name"], "role": r["role"]}
            for r in rows]


def _orgs_brief(orgs: list) -> list:
    """Компактная выдача для login/register/verify: [{org_id, role}]."""
    return [{"org_id": o["org_id"], "role": o["role"]} for o in orgs]


def _create_org(conn, name: str, user_id: str, role: str = "owner") -> dict:
    org_id = secrets.token_hex(16)
    now = time.time()
    conn.execute(
        "INSERT INTO organizations (id, name, created_by, created_at, "
        "updated_at) VALUES (?, ?, ?, ?, ?)",
        (org_id, name, user_id, now, now))
    conn.execute(
        "INSERT INTO memberships (id, org_id, user_id, role, invited_by, "
        "created_at) VALUES (?, ?, ?, ?, ?, ?)",
        (secrets.token_hex(16), org_id, user_id, role, None, now))
    return {"org_id": org_id, "name": name, "role": role}


def _member(conn, org_id: str, user_id: str) -> Optional[dict]:
    row = conn.execute(
        "SELECT role FROM memberships WHERE org_id = ? AND user_id = ?",
        (org_id, user_id)).fetchone()
    return None if row is None else {"org_id": org_id, "role": row["role"]}


def _require_admin(conn, org_id: str, user_id: str) -> dict:
    m = _member(conn, org_id, user_id)
    if m is None:
        raise HTTPException(status_code=403, detail="Нет доступа к организации")
    if m["role"] not in ADMIN_ROLES:
        raise HTTPException(status_code=403, detail="Требуется роль owner/admin")
    return m


def _apply_invites(conn, email: str, user_id: str) -> None:
    """Автоприём живых приглашений по email (вызывается в транзакции регистрации).

    Безопасно без подтверждения кода: email подтверждается паролем при
    регистрации (F-19, HANDOFF §9 п.5).
    """
    now = time.time()
    rows = conn.execute(
        "SELECT id, org_id, role, invited_by FROM invites "
        "WHERE email = ? AND accepted_at IS NULL AND expires_at > ?",
        (email, now)).fetchall()
    for r in rows:
        conn.execute(
            "INSERT INTO memberships (id, org_id, user_id, role, invited_by, "
            "created_at) VALUES (?, ?, ?, ?, ?, ?)",
            (secrets.token_hex(16), r["org_id"], user_id, r["role"],
             r["invited_by"], now))
        conn.execute("UPDATE invites SET accepted_at = ? WHERE id = ?",
                     (now, r["id"]))


# ---------- почта (сброс пароля) ----------

def _smtp_config() -> Optional[dict]:
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


def _new_reset_code(email: str, user_id: Optional[str]) -> str:
    """Одноразовый код: в БД только sha256, TTL PP_RESET_TTL.

    При user_id = None (email не найден) код не сохраняется — наружу
    ответ всё равно одинаковый.
    """
    code = "".join(secrets.choice(digits) for _ in range(RESET_CODE_LEN))
    if user_id is None:
        return code
    now = time.time()
    with _db_lock, _connect() as conn:
        conn.execute("DELETE FROM reset_codes WHERE email = ?", (email,))
        conn.execute(
            "INSERT INTO reset_codes (email, user_id, code_hash, created_at, "
            "expires_at, used) VALUES (?, ?, ?, ?, ?, 0)",
            (email, user_id, _sha256(code), now, now + RESET_TTL_S))
    return code


def _use_reset_code(email: str, user_id: str, code: str) -> bool:
    """Проверка кода: sha256 совпадает, не использован, не просрочен."""
    now = time.time()
    with _db_lock, _connect() as conn:
        row = conn.execute(
            "SELECT code_hash, expires_at, used FROM reset_codes "
            "WHERE email = ? AND (user_id = ? OR user_id IS NULL) "
            "ORDER BY created_at DESC LIMIT 1",
            (email, user_id)).fetchone()
        if row is None or row["used"] or row["expires_at"] < now:
            return False
        if not hmac.compare_digest(row["code_hash"], _sha256(code)):
            return False
        conn.execute("DELETE FROM reset_codes WHERE email = ?", (email,))
        return True


# ---------- модели ----------

class RegisterIn(BaseModel):
    email: str = Field(min_length=3, max_length=254)
    password: str = Field(min_length=6, max_length=128)
    org_name: Optional[str] = Field(default=None, max_length=200)
    device_id: Optional[str] = Field(default=None, max_length=128)


class LoginIn(BaseModel):
    email: str = Field(min_length=3, max_length=254)
    password: str = Field(min_length=1, max_length=128)
    device_id: Optional[str] = Field(default=None, max_length=128)


class OrgIn(BaseModel):
    name: str = Field(min_length=1, max_length=200)


class ForgotIn(BaseModel):
    email: str = Field(min_length=3, max_length=254)


class ResetIn(BaseModel):
    email: str = Field(min_length=3, max_length=254)
    code: str = Field(min_length=RESET_CODE_LEN, max_length=RESET_CODE_LEN)
    new_password: str = Field(min_length=6, max_length=128)


class MemberAddIn(BaseModel):
    email: str = Field(min_length=3, max_length=254)
    role: str = Field(default="member", pattern="^(member|viewer)$")


class InviteAcceptIn(BaseModel):
    code: str = Field(min_length=1, max_length=64)


def _user_row(row) -> dict:
    return {"id": row["id"], "email": row["email"],
            "created_at": row["created_at"]}


# ---------- app ----------

@asynccontextmanager
async def _lifespan(app: FastAPI):
    _init_db()
    yield


app = FastAPI(title="Препресс-Планер: авторизация", version="0.3.0",
              lifespan=_lifespan)

_init_db()


def _auth_dep(authorization: Optional[str] = Header(default=None)) -> dict:
    if not authorization or not authorization.startswith("Bearer "):
        raise HTTPException(status_code=401, detail="Требуется токен")
    try:
        return _session_claims(authorization[7:].strip())
    except ValueError as e:
        raise HTTPException(status_code=401, detail=str(e))


def _create_user(conn, email: str, password: str) -> str:
    user_id = secrets.token_hex(16)
    now = time.time()
    conn.execute(
        "INSERT INTO users (id, email, password_hash, created_at, updated_at) "
        "VALUES (?, ?, ?, ?, ?)",
        (user_id, email, _hash_password(password), now, now))
    return user_id


@app.post("/auth/register", status_code=201)
def register(body: RegisterIn):
    """Регистрация: пользователь + (опционально) организация с ролью owner.

    org_name передан → организация создаётся; не передан → личная
    организация (PP_DEFAULT_ORG=1) либо пользователь без организации.
    Возвращает серверную сессию (мультисессии разрешены).
    """
    email = body.email.lower().strip()
    _check_email(email)
    org_name = (body.org_name or "").strip() or None
    with _db_lock, _connect() as conn:
        existing = conn.execute(
            "SELECT id FROM users WHERE email = ?", (email,)).fetchone()
        if existing is not None:
            raise HTTPException(status_code=409,
                                detail="Email уже зарегистрирован")
        user_id = _create_user(conn, email, body.password)
        # Автоприём живых приглашений по email — в той же транзакции.
        _apply_invites(conn, email, user_id)
        if org_name is None and DEFAULT_ORG:
            org_name = email
        if org_name is not None:
            _create_org(conn, org_name, user_id, "owner")
        token = _issue_session(conn, user_id, body.device_id)
        row = conn.execute(
            "SELECT * FROM users WHERE id = ?", (user_id,)).fetchone()
        orgs = _orgs_of(conn, user_id)
    return {"token": token, "user": _user_row(row), "orgs": _orgs_brief(orgs)}


@app.post("/auth/login")
def login(body: LoginIn):
    """Вход: новая серверная сессия; прежние сессии НЕ вытесняются."""
    email = body.email.lower().strip()
    _check_email(email)
    with _db_lock, _connect() as conn:
        row = conn.execute(
            "SELECT * FROM users WHERE email = ?", (email,)).fetchone()
        if row is None or not _verify_password(body.password,
                                               row["password_hash"]):
            raise HTTPException(status_code=401,
                                detail="Неверный email или пароль")
        token = _issue_session(conn, row["id"], body.device_id)
        orgs = _orgs_of(conn, row["id"])
    return {"token": token, "user": _user_row(row), "orgs": _orgs_brief(orgs)}


@app.post("/auth/logout")
def logout(user: dict = Depends(_auth_dep),
           authorization: Optional[str] = Header(default=None)):
    """Серверные сессии: удаляем именно эту (отзыв реально работает)."""
    token = authorization[7:].strip() if authorization else ""
    with _db_lock, _connect() as conn:
        conn.execute(
            "DELETE FROM sessions WHERE token_hash = ?", (_sha256(token),))
    return {"ok": True, "user_id": user["sub"]}


@app.get("/auth/me")
def me(user: dict = Depends(_auth_dep)):
    """Текущий пользователь со своими организациями и ролями."""
    with _db_lock, _connect() as conn:
        row = conn.execute(
            "SELECT * FROM users WHERE id = ?", (user["sub"],)).fetchone()
        if row is None:
            raise HTTPException(status_code=401, detail="Пользователь не найден")
        orgs = _orgs_of(conn, user["sub"])
    return {
        "user": _user_row(row),
        "orgs": _orgs_brief(orgs),
        "memberships": orgs,
        "session": {"id": user["session_id"][:16],
                    "device_id": user["device_id"]},
    }


@app.get("/auth/sessions")
def sessions(user: dict = Depends(_auth_dep)):
    """Активные сессии пользователя (мультисессии; лимита 1/1 больше нет)."""
    with _db_lock, _connect() as conn:
        rows = conn.execute(
            "SELECT token_hash, device_id, created_at, expires_at "
            "FROM sessions WHERE user_id = ? AND expires_at > ? "
            "AND revoked_at IS NULL ORDER BY created_at DESC",
            (user["sub"], time.time())).fetchall()
    items = [{
        "id": r["token_hash"][:16],
        "device_id": r["device_id"],
        "current": r["token_hash"] == user["session_id"],
        "created_at": r["created_at"],
        "expires_at": r["expires_at"],
    } for r in rows]
    return {"sessions": items, "count": len(items)}


@app.post("/auth/sessions/{session_id}/revoke")
def revoke_session(session_id: str, user: dict = Depends(_auth_dep)):
    with _db_lock, _connect() as conn:
        rows = conn.execute(
            "SELECT token_hash FROM sessions WHERE user_id = ?",
            (user["sub"],)).fetchall()
        target = next((r["token_hash"] for r in rows
                       if r["token_hash"].startswith(session_id)), None)
        if target is None:
            raise HTTPException(status_code=404, detail="Сессия не найдена")
        conn.execute(
            "DELETE FROM sessions WHERE token_hash = ?", (target,))
    return {"ok": True, "revoked": target[:16]}


@app.get("/auth/devices")
def devices(user: dict = Depends(_auth_dep)):
    """Совместимость с desktop-клиентом: то же, что /auth/sessions.

    Политики вытеснения нет — список может содержать несколько записей.
    """
    data = sessions(user)
    return {"devices": data["sessions"], "current":
            next((s["id"] for s in data["sessions"] if s["current"]), None),
            "count": data["count"], "device_policy": "multi"}


@app.get("/auth/orgs")
def list_orgs(user: dict = Depends(_auth_dep)):
    with _db_lock, _connect() as conn:
        rows = conn.execute(
            "SELECT m.org_id, m.role, o.name, m.created_at "
            "FROM memberships m LEFT JOIN organizations o ON o.id = m.org_id "
            "WHERE m.user_id = ? ORDER BY m.created_at ASC",
            (user["sub"],)).fetchall()
    return {"orgs": [{"org_id": r["org_id"], "name": r["name"],
                      "role": r["role"], "created_at": r["created_at"]}
                     for r in rows]}


@app.post("/auth/orgs", status_code=201)
def create_org(body: OrgIn, user: dict = Depends(_auth_dep)):
    """Новая организация; создатель — owner."""
    name = body.name.strip()
    if not name:
        raise HTTPException(status_code=422, detail="Пустое название")
    with _db_lock, _connect() as conn:
        org = _create_org(conn, name, user["sub"], "owner")
    return org


# ---------- участники и приглашения (F-19, HANDOFF §9 п.5) ----------

@app.get("/auth/orgs/{org_id}/members")
def list_members(org_id: str, user: dict = Depends(_auth_dep)):
    """Список участников организации: любой член (включая viewer)."""
    with _db_lock, _connect() as conn:
        if _member(conn, org_id, user["sub"]) is None:
            raise HTTPException(status_code=403,
                                detail="Нет доступа к организации")
        rows = conn.execute(
            "SELECT m.user_id, u.email, m.role, m.invited_by, m.created_at "
            "FROM memberships m JOIN users u ON u.id = m.user_id "
            "WHERE m.org_id = ? ORDER BY m.created_at ASC",
            (org_id,)).fetchall()
    return {"members": [{"user_id": r["user_id"], "email": r["email"],
                         "role": r["role"], "invited_by": r["invited_by"],
                         "created_at": r["created_at"]} for r in rows]}


@app.post("/auth/orgs/{org_id}/members", status_code=201)
def add_member(org_id: str, body: MemberAddIn,
               user: dict = Depends(_auth_dep)):
    """Добавить участника (существующий email) или создать приглашение.

    role — только member|viewer (иное 422). Приглашение живёт 7 дней;
    без SMTP код возвращается в ответе (dev-режим), с SMTP — уходит письмом.
    """
    email = body.email.lower().strip()
    _check_email(email)
    with _db_lock, _connect() as conn:
        _require_admin(conn, org_id, user["sub"])
        now = time.time()
        target = conn.execute(
            "SELECT id FROM users WHERE email = ?", (email,)).fetchone()
        if target is not None:
            if _member(conn, org_id, target["id"]) is not None:
                raise HTTPException(status_code=409,
                                    detail="Пользователь уже участник организации")
            conn.execute(
                "INSERT INTO memberships (id, org_id, user_id, role, "
                "invited_by, created_at) VALUES (?, ?, ?, ?, ?, ?)",
                (secrets.token_hex(16), org_id, target["id"], body.role,
                 user["sub"], now))
            row = conn.execute(
                "SELECT m.user_id, u.email, m.role, m.invited_by, "
                "m.created_at FROM memberships m "
                "JOIN users u ON u.id = m.user_id "
                "WHERE m.org_id = ? AND m.user_id = ?",
                (org_id, target["id"])).fetchone()
            return {"status": "added",
                    "member": {"user_id": row["user_id"], "email": row["email"],
                               "role": row["role"], "invited_by": row["invited_by"],
                               "created_at": row["created_at"]}}

        live = conn.execute(
            "SELECT id FROM invites WHERE org_id = ? AND email = ? "
            "AND accepted_at IS NULL AND expires_at > ?",
            (org_id, email, now)).fetchone()
        if live is not None:
            raise HTTPException(status_code=409,
                                detail="Приглашение для этого email уже отправлено")
        code = secrets.token_hex(8)  # 16 hex-символов
        invite_id = secrets.token_hex(16)
        expires_at = now + INVITE_TTL_S
        conn.execute(
            "INSERT INTO invites (id, org_id, email, role, code_hash, "
            "invited_by, created_at, expires_at, accepted_at) "
            "VALUES (?, ?, ?, ?, ?, ?, ?, ?, NULL)",
            (invite_id, org_id, email, body.role, _sha256(code),
             user["sub"], now, expires_at))
    smtp = _smtp_config()
    smtp_sent = False
    if smtp is not None:
        try:
            _send_email(
                email,
                "Приглашение в организацию — Препресс-Планер",
                f"Вас приглашают в организацию (роль: {body.role}).\n"
                f"Код приглашения: {code}\n"
                f"Код действителен 7 дней.")
            smtp_sent = True
        except Exception:
            # Сбой SMTP не ломает приглашение: код остаётся в БД (hash).
            smtp_sent = False
    resp = {"status": "invited", "invite_id": invite_id,
            "expires_at": expires_at, "smtp_sent": smtp_sent}
    if not smtp_sent and smtp is None:
        resp["code"] = code  # dev-режим без SMTP — код в ответе
    return resp


@app.post("/auth/orgs/{org_id}/invites/accept")
def accept_invite(org_id: str, body: InviteAcceptIn,
                  user: dict = Depends(_auth_dep)):
    """Принятие приглашения по коду: email сессии должен совпадать с invite."""
    with _db_lock, _connect() as conn:
        row = conn.execute(
            "SELECT * FROM invites WHERE org_id = ? AND code_hash = ?",
            (org_id, _sha256(body.code.strip()))).fetchone()
        if row is None:
            raise HTTPException(status_code=404, detail="Приглашение не найдено")
        if row["email"] != user["email"].lower():
            raise HTTPException(status_code=403,
                                detail="Приглашение предназначено для другого email")
        if row["accepted_at"] is not None:
            raise HTTPException(status_code=409, detail="Приглашение уже принято")
        if row["expires_at"] < time.time():
            raise HTTPException(status_code=409, detail="Приглашение истекло")
        if _member(conn, org_id, user["sub"]) is not None:
            raise HTTPException(status_code=409,
                                detail="Вы уже участник организации")
        now = time.time()
        conn.execute(
            "INSERT INTO memberships (id, org_id, user_id, role, invited_by, "
            "created_at) VALUES (?, ?, ?, ?, ?, ?)",
            (secrets.token_hex(16), org_id, user["sub"], row["role"],
             row["invited_by"], now))
        conn.execute("UPDATE invites SET accepted_at = ? WHERE id = ?",
                     (now, row["id"]))
    return {"ok": True, "org_id": org_id, "role": row["role"]}


@app.delete("/auth/orgs/{org_id}/members/{user_id}")
def remove_member(org_id: str, user_id: str,
                  user: dict = Depends(_auth_dep)):
    """Удаление участника; последнего owner удалить нельзя (409)."""
    with _db_lock, _connect() as conn:
        _require_admin(conn, org_id, user["sub"])
        target = _member(conn, org_id, user_id)
        if target is None:
            raise HTTPException(status_code=404, detail="Участник не найден")
        if target["role"] == "owner":
            owners = conn.execute(
                "SELECT COUNT(*) AS n FROM memberships "
                "WHERE org_id = ? AND role = 'owner'", (org_id,)).fetchone()
            if owners["n"] <= 1:
                raise HTTPException(
                    status_code=409,
                    detail="Нельзя удалить последнего owner организации")
        conn.execute(
            "DELETE FROM memberships WHERE org_id = ? AND user_id = ?",
            (org_id, user_id))
    return {"ok": True}


@app.post("/auth/verify")
def verify(authorization: Optional[str] = Header(default=None)):
    """Внутренний вызов (billing/api): токен → {sub, email, orgs}."""
    if not authorization or not authorization.startswith("Bearer "):
        raise HTTPException(status_code=401, detail="Требуется токен")
    try:
        claims = _session_claims(authorization[7:].strip())
    except ValueError as e:
        raise HTTPException(status_code=401, detail=str(e))
    with _db_lock, _connect() as conn:
        orgs = _orgs_of(conn, claims["sub"])
    return {"sub": claims["sub"], "email": claims["email"],
            "orgs": _orgs_brief(orgs)}


@app.post("/auth/forgot")
def forgot(body: ForgotIn):
    """Запрос сброса: код (6 цифр, TTL PP_RESET_TTL) уходит только по SMTP.

    Ответ всегда {ok: true} — код и факт существования email не раскрываются
    (в т.ч. в dev-режиме без SMTP; dev_code удалён из контракта).
    """
    email = body.email.lower().strip()
    _check_email(email)
    with _db_lock, _connect() as conn:
        row = conn.execute(
            "SELECT id FROM users WHERE email = ?", (email,)).fetchone()
    user_id = row["id"] if row is not None else None
    code = _new_reset_code(email, user_id)
    smtp = _smtp_config()
    if smtp is not None and user_id is not None:
        try:
            _send_email(
                email,
                "Сброс пароля — Препресс-Планер",
                f"Код для сброса пароля: {code}\n"
                f"Код действителен {int(RESET_TTL_MIN)} минут.")
        except Exception:
            # Недоступность SMTP не раскрывает код клиенту (ретраи — в runbook).
            pass
    return {"ok": True}


@app.post("/auth/reset")
def reset(body: ResetIn):
    """Смена пароля по коду: код одноразовый, все сессии пользователя отзываются."""
    email = body.email.lower().strip()
    _check_email(email)
    with _db_lock, _connect() as conn:
        row = conn.execute(
            "SELECT id FROM users WHERE email = ?", (email,)).fetchone()
        if row is None:
            raise HTTPException(status_code=404,
                                detail="Пользователь не найден")
        user_id = row["id"]
        if not _use_reset_code(email, user_id, body.code):
            raise HTTPException(status_code=400,
                                detail="Неверный или истёкший код")
        now = time.time()
        conn.execute(
            "UPDATE users SET password_hash = ?, updated_at = ? WHERE id = ?",
            (_hash_password(body.new_password), now, user_id))
        # Безопасность: отзываем ВСЕ сессии пользователя.
        conn.execute("DELETE FROM sessions WHERE user_id = ?", (user_id,))
    return {"ok": True}


@app.get("/healthz")
def healthz():
    smtp = _smtp_config()
    return {"status": "ok", "service": "auth", "version": app.version,
            "db": str(DB_PATH), "sessions": "server-side",
            "device_policy": "multi", "device_limit": None,
            "multitenant": True, "roles": list(ROLES),
            "default_org": DEFAULT_ORG, "smtp": bool(smtp),
            "reset_ttl_min": RESET_TTL_MIN}
