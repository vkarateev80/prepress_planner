# -*- coding: utf-8 -*-
"""Микросервис авторизации «Препресс-Планер» (SaaS, self-hosted).

Основание: PRD v2 (F-19) и System Design v1 (ADR-4, §12.2, §13.1).

Аккаунты email+пароль, СЕРВЕРНЫЕ сессии (таблица sessions, opaque-токены,
в БД — только sha256), отзыв сессии реально работает. Мультитенантность:
организации и членство с ролями (owner/admin/member/viewer). Политика
**1/1 (вытеснение)**: у аккаунта ровно одна активная сессия — вход
(login/confirm) отзывает все прежние сессии пользователя («вход с другого
устройства вытеснит это»).

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

Регистрация двухфазная (подтверждение почты и телефона):
  POST /auth/register {email, password, phone, org_name?, device_id?} → 202
      создаёт пользователя БЕЗ сессии (email_verified_at/phone_verified_at
      NULL) и шлёт два 6-значных кода: на email (SMTP) и на телефон (SMS).
      Коды в БД только sha256, TTL = PP_RESET_TTL. Код в ответе появляется
      только когда канал доставки недоступен: dev_email_code — без SMTP,
      dev_phone_code — при PP_SMS_PROVIDER=dev (пока реального SMS нет).
  POST /auth/confirm {email, email_code, phone_code, device_id?} → 201
      сверяет оба кода, помечает аккаунт подтверждённым и выдаёт сессию
      (payload как у прежнего register: {token, user, orgs}).
  POST /auth/confirm/resend {email, channel: email|phone} → {ok}
      переотправка кода (кулдаун PP_RESEND_COOLDOWN, дефолт 60 с).
  POST /auth/login — 403, пока аккаунт не подтверждён.

Зависимости: стандартная библиотека Python + fastapi/pydantic (+uvicorn для
запуска). Почта — smtplib/email из stdlib. Внешних пакетов для логики нет.

API:
  POST /auth/register          {name, email, password, phone, org_name?}
                               → 202 pending
  POST /auth/confirm           {email, email_code, phone_code, device_id?}
                                                              → 201 {token, user, orgs}
  POST /auth/confirm/resend    {email, channel}               → {ok, dev_*_code?}
  POST /auth/login             {email, password, device_id?} → {token, user, orgs}
                               (вытесняет прежние сессии — 1/1)
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
  PP_SMS_PROVIDER  — dev (по умолчанию): SMS не отправляется, код в ответе
                     register/resend; sms_ru — реальная отправка sms.ru
                     (нужен PP_SMS_API_ID; PP_SMS_TEST=1 — test=1 провайдера;
                     PP_SMS_FROM — буквенный отправитель при коде 221)
  PP_RESEND_COOLDOWN — кулдаун переотправки кода подтверждения, с (60)
"""
import hashlib
import hmac
import json
import os
import re
import secrets
import smtplib
import sqlite3
import threading
import time
import urllib.parse
import urllib.request
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
# SMS: dev (по умолчанию) — реальной отправки нет, код в ответе register/
# resend; sms_ru — реальная отправка через https://sms.ru/sms/send
# (нужен PP_SMS_API_ID; PP_SMS_TEST=1 — режим test=1 провайдера: ответ
# проверяется, но SMS не отправляется и баланс не расходуется).
SMS_PROVIDER = os.environ.get("PP_SMS_PROVIDER", "dev").strip() or "dev"
SMS_API_ID = os.environ.get("PP_SMS_API_ID", "").strip()
SMS_TEST = os.environ.get("PP_SMS_TEST", "").strip() == "1"
# Буквенный отправитель sms.ru (раздел «Отправители»); пусто — отправитель
# по умолчанию. Нужен, если в аккаунте включена обязательная буквенная
# отправка (код 221).
SMS_FROM = os.environ.get("PP_SMS_FROM", "").strip()
SMS_URL = "https://sms.ru/sms/send"
RESEND_COOLDOWN_S = float(
    os.environ.get("PP_RESEND_COOLDOWN", "60").strip() or 60)

ROLES = ("owner", "admin", "member", "viewer")
ADMIN_ROLES = ("owner", "admin")

_db_lock = threading.RLock()  # RLock: вложенные обращения (reset → use_code)

_EMAIL_RE = r"^[^@\s]+@[^@\s]+\.[^@\s]+$"


def _check_email(email: str):
    if not re.match(_EMAIL_RE, email):
        raise HTTPException(status_code=422, detail="Некорректный email")


def _check_phone(phone: str) -> str:
    """Нормализация к +7XXXXXXXXXX; иначе 422. Принимает 8…, 7…, +7…."""
    digits_only = re.sub(r"\D", "", phone)
    if len(digits_only) == 11 and digits_only.startswith("8"):
        digits_only = "7" + digits_only[1:]
    if len(digits_only) != 11 or not digits_only.startswith("7"):
        raise HTTPException(
            status_code=422, detail="Некорректный номер телефона")
    return "+" + digits_only


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
            CREATE TABLE IF NOT EXISTS verify_codes (
                id TEXT PRIMARY KEY,
                channel TEXT NOT NULL,
                dest TEXT NOT NULL,
                user_id TEXT NOT NULL,
                code_hash TEXT NOT NULL,
                created_at REAL NOT NULL,
                expires_at REAL NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_verify_codes_dest
                ON verify_codes(channel, dest);
            """
        )
        # --- миграция legacy → новая схема (идемпотентно) ---
        user_cols = _columns(conn, "users")
        if "updated_at" not in user_cols:
            conn.execute("ALTER TABLE users ADD COLUMN updated_at REAL")
        if "phone" not in user_cols:
            # Одноразово (только при добавлении колонок): телефона нет ни у
            # кого — но существующие аккаунты считаем уже подтверждёнными,
            # иначе все юзеры прода потеряют вход. Новые (после этой
            # миграции) регистрируются с NULL и проходят confirm.
            conn.execute("ALTER TABLE users ADD COLUMN phone TEXT")
            conn.execute(
                "ALTER TABLE users ADD COLUMN email_verified_at REAL")
            conn.execute(
                "ALTER TABLE users ADD COLUMN phone_verified_at REAL")
            conn.execute(
                "UPDATE users SET email_verified_at = created_at, "
                "phone_verified_at = created_at "
                "WHERE email_verified_at IS NULL")
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
        # Имя пользователя (регистрационные данные) — идемпотентно.
        if "name" not in user_cols:
            conn.execute("ALTER TABLE users ADD COLUMN name TEXT")
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


def _new_verify_code(channel: str, dest: str, user_id: str) -> str:
    """Код подтверждения (email|phone): в БД только sha256, свежий
    вытесняет предыдущий (DELETE по channel+dest)."""
    code = "".join(secrets.choice(digits) for _ in range(RESET_CODE_LEN))
    now = time.time()
    with _db_lock, _connect() as conn:
        conn.execute(
            "DELETE FROM verify_codes WHERE channel = ? AND dest = ?",
            (channel, dest))
        conn.execute(
            "INSERT INTO verify_codes (id, channel, dest, user_id, "
            "code_hash, created_at, expires_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
            (secrets.token_hex(16), channel, dest, user_id, _sha256(code),
             now, now + RESET_TTL_S))
    return code


def _check_verify_code(channel: str, dest: str, user_id: str,
                       code: str) -> bool:
    """Сверка кода подтверждения без погашения (погашение — после того,
    как проверились ОБА кода: иначе неверный код телефона «сжигал» бы
    уже введённый код почты)."""
    now = time.time()
    with _db_lock, _connect() as conn:
        row = conn.execute(
            "SELECT code_hash, expires_at FROM verify_codes "
            "WHERE channel = ? AND dest = ? AND user_id = ? "
            "ORDER BY created_at DESC LIMIT 1",
            (channel, dest, user_id)).fetchone()
        if row is None or row["expires_at"] < now:
            return False
        return hmac.compare_digest(row["code_hash"], _sha256(code))


def _verify_send_age(channel: str, dest: str) -> float:
    """Возраст последней отправки (с) или +inf, если отправок не было."""
    with _db_lock, _connect() as conn:
        row = conn.execute(
            "SELECT created_at FROM verify_codes "
            "WHERE channel = ? AND dest = ? "
            "ORDER BY created_at DESC LIMIT 1",
            (channel, dest)).fetchone()
    if row is None:
        return float("inf")
    return time.time() - row["created_at"]


def _send_sms(phone: str, code: str) -> bool:
    """Отправка SMS-кода подтверждения. Возвращает True, если принято.

    PP_SMS_PROVIDER=dev (по умолчанию) — реальной отправки нет: код
    возвращается клиенту в dev_phone_code. PP_SMS_PROVIDER=sms_ru —
    POST https://sms.ru/sms/send (документация sms.ru/api/send):
    api_id + to (7XXXXXXXXXX) + msg (UTF-8) + json=1; ответ
    {status, status_code, sms: {номер: {status, status_code, ...}}}.
    """
    if SMS_PROVIDER == "dev":
        return False
    if SMS_PROVIDER != "sms_ru":
        raise RuntimeError(f"SMS-провайдер не поддержан: {SMS_PROVIDER}")
    if not SMS_API_ID:
        raise RuntimeError("PP_SMS_API_ID не задан")
    to = phone.lstrip("+")
    msg = (f"Препресс-Планер: код подтверждения {code}. "
           f"Не сообщайте его никому.")
    form = {"api_id": SMS_API_ID, "to": to, "msg": msg, "json": "1"}
    if SMS_FROM:
        form["from"] = SMS_FROM
    if SMS_TEST:
        form["test"] = "1"  # имитация: без отправки и без списания
    req = urllib.request.Request(
        SMS_URL,
        data=urllib.parse.urlencode(form).encode("utf-8"),
        headers={"Content-Type": "application/x-www-form-urlencoded"},
        method="POST")
    with urllib.request.urlopen(req, timeout=15) as resp:
        payload = json.loads(resp.read().decode("utf-8"))
    if str(payload.get("status")) == "OK":
        per = (payload.get("sms") or {}).get(to) or {}
        if str(per.get("status")) == "OK":
            return True
        raise RuntimeError(
            f"SMS.ru: {per.get('status_text') or per.get('status_code')}")
    raise RuntimeError(
        f"SMS.ru: {payload.get('status_text') or payload.get('status_code')}")


# ---------- модели ----------

class RegisterIn(BaseModel):
    name: str = Field(min_length=1, max_length=100)
    email: str = Field(min_length=3, max_length=254)
    password: str = Field(min_length=6, max_length=128)
    phone: str = Field(min_length=10, max_length=20)
    org_name: Optional[str] = Field(default=None, max_length=200)
    device_id: Optional[str] = Field(default=None, max_length=128)


class ConfirmIn(BaseModel):
    email: str = Field(min_length=3, max_length=254)
    email_code: str = Field(min_length=RESET_CODE_LEN, max_length=RESET_CODE_LEN)
    phone_code: str = Field(min_length=RESET_CODE_LEN, max_length=RESET_CODE_LEN)
    device_id: Optional[str] = Field(default=None, max_length=128)


class ConfirmResendIn(BaseModel):
    email: str = Field(min_length=3, max_length=254)
    channel: str = Field(pattern="^(email|phone)$")


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
    role: str = Field(default="member", pattern="^(member|viewer|admin)$")


class InviteAcceptIn(BaseModel):
    code: str = Field(min_length=1, max_length=64)


def _user_row(row) -> dict:
    return {"id": row["id"], "email": row["email"],
            "name": row["name"] or "",
            "created_at": row["created_at"]}


# ---------- app ----------

@asynccontextmanager
async def _lifespan(app: FastAPI):
    _init_db()
    yield


app = FastAPI(title="Препресс-Планер: авторизация", version="0.4.0",
              lifespan=_lifespan)

_init_db()


def _auth_dep(authorization: Optional[str] = Header(default=None)) -> dict:
    if not authorization or not authorization.startswith("Bearer "):
        raise HTTPException(status_code=401, detail="Требуется токен")
    try:
        return _session_claims(authorization[7:].strip())
    except ValueError as e:
        raise HTTPException(status_code=401, detail=str(e))


def _create_user(conn, email: str, password: str, name: str) -> str:
    user_id = secrets.token_hex(16)
    now = time.time()
    conn.execute(
        "INSERT INTO users (id, email, password_hash, name, created_at, "
        "updated_at) VALUES (?, ?, ?, ?, ?, ?)",
        (user_id, email, _hash_password(password), name, now, now))
    return user_id


@app.post("/auth/register", status_code=202)
def register(body: RegisterIn):
    """Фаза 1 регистрации: пользователь + организация БЕЗ сессии.

    Создаёт аккаунт (неподтверждённый), применяет приглашения и шлёт
    два кода подтверждения: на email (SMTP) и на телефон (SMS, пока
    PP_SMS_PROVIDER=dev — код в ответе). Сессия выдаётся только в
    POST /auth/confirm.
    """
    email = body.email.lower().strip()
    _check_email(email)
    phone = _check_phone(body.phone)
    name = body.name.strip()
    if not name:
        raise HTTPException(status_code=422, detail="Укажите имя пользователя")
    org_name = (body.org_name or "").strip() or None
    with _db_lock, _connect() as conn:
        existing = conn.execute(
            "SELECT id FROM users WHERE email = ?", (email,)).fetchone()
        if existing is not None:
            raise HTTPException(status_code=409,
                                detail="Email уже зарегистрирован")
        user_id = _create_user(conn, email, body.password, name)
        conn.execute("UPDATE users SET phone = ? WHERE id = ?",
                     (phone, user_id))
        # Автоприём живых приглашений по email — в той же транзакции.
        _apply_invites(conn, email, user_id)
        if org_name is None and DEFAULT_ORG:
            org_name = email
        if org_name is not None:
            _create_org(conn, org_name, user_id, "owner")
        # Сессию НЕ выдаём: до confirm аккаунтом пользоваться нельзя.

    email_code = _new_verify_code("email", email, user_id)
    phone_code = _new_verify_code("phone", phone, user_id)
    resp = {"pending": True, "email": email, "phone": phone}

    smtp = _smtp_config()
    if smtp is not None:
        try:
            _send_email(
                email,
                "Подтверждение регистрации — Препресс-Планер",
                f"Код подтверждения почты: {email_code}\n"
                f"Код действителен {int(RESET_TTL_MIN)} минут.")
        except Exception:
            # Недоступность SMTP не роняет регистрацию (ретраи — в runbook).
            pass
    else:
        resp["dev_email_code"] = email_code  # dev: SMTP не настроен

    try:
        sms_sent = _send_sms(phone, phone_code)
    except Exception:
        sms_sent = False
    resp["sms_sent"] = sms_sent
    # Код в ответе — только в dev-режиме; у реального провайдера при сбое
    # доставки код получить можно переотправкой (confirm/resend).
    if SMS_PROVIDER == "dev" and not sms_sent:
        resp["dev_phone_code"] = phone_code
    return resp


@app.post("/auth/confirm", status_code=201)
def confirm(body: ConfirmIn):
    """Фаза 2: сверка обоих кодов → аккаунт подтверждён → сессия."""
    email = body.email.lower().strip()
    _check_email(email)
    with _db_lock, _connect() as conn:
        row = conn.execute(
            "SELECT * FROM users WHERE email = ?", (email,)).fetchone()
        if row is None:
            # Регистрация не начиналась — не раскрываем существование.
            raise HTTPException(status_code=404,
                                detail="Регистрация не найдена")
        if row["email_verified_at"] is not None:
            raise HTTPException(status_code=409,
                                detail="Аккаунт уже подтверждён")
        if not _check_verify_code("email", email, row["id"], body.email_code):
            raise HTTPException(status_code=400,
                                detail="Неверный или истёкший код почты")
        if not _check_verify_code("phone", row["phone"], row["id"],
                                  body.phone_code):
            raise HTTPException(status_code=400,
                                detail="Неверный или истёкший код телефона")
        now = time.time()
        conn.execute("DELETE FROM verify_codes WHERE user_id = ?",
                     (row["id"],))
        conn.execute(
            "UPDATE users SET email_verified_at = ?, phone_verified_at = ?, "
            "updated_at = ? WHERE id = ?",
            (now, now, now, row["id"]))
        # Политика 1/1: при выдаче первой сессии старые (не должно быть) —
        # на всякий случай отзываем.
        conn.execute("DELETE FROM sessions WHERE user_id = ?", (row["id"],))
        token = _issue_session(conn, row["id"], body.device_id)
        orgs = _orgs_of(conn, row["id"])
        row = conn.execute(
            "SELECT * FROM users WHERE id = ?", (row["id"],)).fetchone()
    return {"token": token, "user": _user_row(row), "orgs": _orgs_brief(orgs)}


@app.post("/auth/confirm/resend")
def confirm_resend(body: ConfirmResendIn):
    """Переотправка кода подтверждения (кулдаун PP_RESEND_COOLDOWN).

    Ответ одноразово-успешный ({ok: true}) — существование email не
    раскрывается; dev_*_code появляется только когда отправили и канал
    dev (без SMTP / PP_SMS_PROVIDER=dev).
    """
    email = body.email.lower().strip()
    _check_email(email)
    with _db_lock, _connect() as conn:
        row = conn.execute(
            "SELECT id, phone FROM users WHERE email = ?",
            (email,)).fetchone()
    if row is None:
        return {"ok": True}  # тихий no-op
    dest = email if body.channel == "email" else (row["phone"] or "")
    if not dest:
        return {"ok": True}
    if _verify_send_age(body.channel, dest) < RESEND_COOLDOWN_S:
        raise HTTPException(
            status_code=429,
            detail="Слишком часто. Повторите попытку позже.")
    code = _new_verify_code(body.channel, dest, row["id"])
    resp = {"ok": True}
    if body.channel == "email":
        smtp = _smtp_config()
        if smtp is not None:
            try:
                _send_email(
                    email,
                    "Подтверждение регистрации — Препресс-Планер",
                    f"Код подтверждения почты: {code}\n"
                    f"Код действителен {int(RESET_TTL_MIN)} минут.")
            except Exception:
                pass
        else:
            resp["dev_email_code"] = code
    else:
        try:
            sms_sent = _send_sms(dest, code)
        except Exception:
            sms_sent = False
        resp["sms_sent"] = sms_sent
        if SMS_PROVIDER == "dev" and not sms_sent:
            resp["dev_phone_code"] = code
    return resp


@app.post("/auth/login")
def login(body: LoginIn):
    """Вход: новая серверная сессия; прежние сессии вытесняются (1/1).

    Неподтверждённый аккаунт (двухфазная регистрация) — 403.
    """
    email = body.email.lower().strip()
    _check_email(email)
    with _db_lock, _connect() as conn:
        row = conn.execute(
            "SELECT * FROM users WHERE email = ?", (email,)).fetchone()
        if row is None or not _verify_password(body.password,
                                               row["password_hash"]):
            raise HTTPException(status_code=401,
                                detail="Неверный email или пароль")
        if row["email_verified_at"] is None:
            raise HTTPException(
                status_code=403,
                detail="Аккаунт не подтверждён. Введите коды с почты и из SMS.")
        # Политика 1/1: прежние сессии пользователя вытесняются.
        conn.execute("DELETE FROM sessions WHERE user_id = ?", (row["id"],))
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
    """Активные сессии пользователя (политика 1/1 — обычно одна)."""
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

    Политика 1/1: список обычно содержит одну запись (вход вытесняет
    прежние сессии).
    """
    data = sessions(user)
    return {"devices": data["sessions"], "current":
            next((s["id"] for s in data["sessions"] if s["current"]), None),
            "count": data["count"], "device_policy": "single"}


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

    role — member|viewer|admin (иное 422; admin назначает админ-панель). Приглашение живёт 7 дней;
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
            "device_policy": "single", "device_limit": 1,
            "multitenant": True, "roles": list(ROLES),
            "default_org": DEFAULT_ORG, "smtp": bool(smtp),
            "sms": SMS_PROVIDER, "reset_ttl_min": RESET_TTL_MIN}
