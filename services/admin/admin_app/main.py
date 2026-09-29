# -*- coding: utf-8 -*-
"""Админ-панель «Препресс-Планер» (отдельный сервис, по решению владельца).

Возможности (первая версия, полный набор):
  * мониторинг: healthz всех сервисов стека + счётчики (аккаунты, проекты,
    заказы, Pro);
  * аккаунты: поиск, активные сессии, отзыв сессий, удаление пользователя;
  * доступы: члены СИСТЕМНОЙ организации (первая по created_at), назначение
    ролей member/viewer/admin через auth API, удаление членства;
  * подписки: выдача/отзыв Pro прямой правкой subscriptions+entitlements
    (возврат реальных средств — через кабинет ЮKassa);
  * заказы: список статусов;
  * БД: read-only просмотр whitelisted-таблиц PostgreSQL.

Доступ: вход через auth (`POST /auth/login`), но панель видна только
пользователям с ролью owner/admin в СИСТЕМНОЙ (первой) организации —
как выбрано владельцем («роль admin/owner»). Новые пользователи становятся
owner только своей личной организации и в панель не попадают.

API (все, кроме login — Bearer):
  POST /admin/api/login            {email, password}     → {token, email}
  GET  /admin/api/overview                               → healthz + счётчики
  GET  /admin/api/users?query=                           → список аккаунтов
  POST /admin/api/users/{id}/revoke-sessions             → {ok, revoked}
  DELETE /admin/api/users/{id}                           → {ok, ...}
  GET  /admin/api/access                                 → члены системной org
  POST /admin/api/access             {email, role}       → прокси auth API
  DELETE /admin/api/access/{user_id}                     → прокси auth API
  GET  /admin/api/subscriptions                          → подписки + Pro
  POST /admin/api/subscriptions      {org_id, action}    → grant|revoke
  GET  /admin/api/orders                                 → заказы
  GET  /admin/api/db/tables                              → whitelist + counts
  GET  /admin/api/db/{table}?limit=&offset=              → строки (read-only)
  GET  /healthz
  GET  /admin/                                          → HTML-панель

env: AUTH_URL (обязателен), DB_URL (обязателен), AUTH_DB_PATH
     (в k8s /srv/auth/data/auth.db, PVC только для чтения).
"""
from __future__ import annotations

import json
import os
import re
import secrets
import sqlite3
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional

from fastapi import Depends, FastAPI, Header, HTTPException
from fastapi.responses import HTMLResponse, RedirectResponse
from pydantic import BaseModel, Field

from .db import AdminDb

AUTH_URL = (os.environ.get("AUTH_URL", "").strip()
            or os.environ.get("PP_AUTH_URL", "").strip()
            or "http://auth:8121").rstrip("/")
DB_URL = os.environ.get("DB_URL", "").strip()
AUTH_DB_PATH = os.environ.get("AUTH_DB_PATH", "").strip() \
    or "/srv/auth/data/auth.db"

# healthz стека (внутренние адресы k8s/compose).
HEALTH_TARGETS = [
    ("web (nginx edge)", "http://web/healthz"),
    ("api", "http://api:8100/healthz"),
    ("auth", "http://auth:8121/healthz"),
    ("billing", "http://billing:8122/healthz"),
    ("converter", "http://converter:8120/healthz"),
    ("domain-worker", "http://domain-worker:8101/healthz"),
    ("minio", "http://minio:9000/minio/health/live"),
]

# Read-only просмотр: только эти таблицы PostgreSQL.
DB_TABLES = ("plans", "projects", "files", "file_versions", "reports",
             "orders", "transactions", "subscriptions", "entitlements")

db = AdminDb(DB_URL) if DB_URL else None  # в тестах DB_URL задаётся до импорта

app = FastAPI(title="Препресс-Планер: админ-панель", version="1.0.0")

INDEX_PATH = Path(__file__).parent / "index.html"


# --------------------------------------------------------------------------
# auth: проверка токена и системная организация
# --------------------------------------------------------------------------

def _auth_request(method: str, path: str, token: Optional[str] = None,
                  body: Optional[Dict[str, Any]] = None,
                  timeout: float = 10.0):
    """HTTP к auth → (status, dict)."""
    data = json.dumps(body).encode("utf-8") if body is not None else None
    headers = {"Content-Type": "application/json"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    req = urllib.request.Request(f"{AUTH_URL}{path}", data=data,
                                 headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            raw = resp.read().decode("utf-8", errors="replace")
            return resp.status, (json.loads(raw) if raw else {})
    except urllib.error.HTTPError as exc:
        raw = exc.read().decode("utf-8", errors="replace")
        try:
            return exc.code, json.loads(raw)
        except ValueError:
            return exc.code, {"detail": raw[:300]}
    except (urllib.error.URLError, TimeoutError, OSError) as exc:
        raise HTTPException(status_code=503,
                            detail=f"Сервис авторизации недоступен: {exc}")


def _auth_rows(sql: str, params: tuple = ()) -> List[Dict[str, Any]]:
    """Чтение auth.db (PVC только для чтения)."""
    conn = sqlite3.connect(f"file:{AUTH_DB_PATH}?mode=ro", uri=True,
                           timeout=5)
    conn.row_factory = sqlite3.Row
    try:
        return [dict(r) for r in conn.execute(sql, params).fetchall()]
    finally:
        conn.close()


def _system_org() -> Dict[str, Any]:
    """Системная организация = первая по created_at (решение владельца)."""
    rows = _auth_rows(
        "SELECT id, name FROM organizations ORDER BY created_at ASC LIMIT 1")
    if not rows:
        raise HTTPException(status_code=503,
                            detail="Системная организация не найдена")
    return rows[0]


def _verify(token: str) -> Dict[str, Any]:
    status, payload = _auth_request("POST", "/auth/verify", token=token)
    if status != 200:
        raise HTTPException(status_code=401,
                            detail=(payload or {}).get("detail")
                            or "Сессия недействительна")
    return payload


def _require_admin(authorization: Optional[str] = Header(default=None)) -> Dict[str, Any]:
    """Bearer → verify → роль owner/admin в системной организации."""
    if not authorization or not authorization.startswith("Bearer "):
        raise HTTPException(status_code=401, detail="Требуется токен")
    token = authorization[7:].strip()
    claims = _verify(token)
    org = _system_org()
    role = next((o.get("role") for o in claims.get("orgs", [])
                 if o.get("org_id") == org["id"]), None)
    if role not in ("owner", "admin"):
        raise HTTPException(
            status_code=403,
            detail="Требуется роль owner или admin в системной организации")
    return {"token": token, "claims": claims, "system_org": org,
            "role": role}


def _db() -> AdminDb:
    if db is None:
        raise HTTPException(status_code=503, detail="DB_URL не задан")
    return db


def _to_iso(ts: float) -> str:
    return datetime.fromtimestamp(ts, timezone.utc).strftime(
        "%Y-%m-%dT%H:%M:%SZ")


# --------------------------------------------------------------------------
# модели
# --------------------------------------------------------------------------

class LoginIn(BaseModel):
    email: str = Field(min_length=3, max_length=254)
    password: str = Field(min_length=1, max_length=128)


class AccessIn(BaseModel):
    email: str = Field(min_length=3, max_length=254)
    role: str = Field(default="member", pattern="^(member|viewer|admin)$")


class SubscriptionActionIn(BaseModel):
    org_id: str = Field(min_length=1, max_length=64)
    action: str = Field(pattern="^(grant|revoke)$")
    plan: str = Field(default="month", pattern="^(month|year)$")


# --------------------------------------------------------------------------
# вход
# --------------------------------------------------------------------------

@app.post("/admin/api/login")
def login(body: LoginIn):
    """Вход: прокси в auth + проверка админ-доступа (системная организация)."""
    status, payload = _auth_request("POST", "/auth/login", body=body.model_dump())
    if status != 200:
        raise HTTPException(status_code=status,
                            detail=(payload or {}).get("detail")
                            or "Неверный email или пароль")
    token = payload.get("token")
    admin = _require_admin(authorization=f"Bearer {token}")
    return {"token": token,
            "email": (admin["claims"].get("email") or body.email),
            "role": admin["role"],
            "system_org": admin["system_org"]}


# --------------------------------------------------------------------------
# обзор: healthz + счётчики
# --------------------------------------------------------------------------

def _probe(name: str, url: str) -> Dict[str, Any]:
    started = time.time()
    try:
        req = urllib.request.Request(url)
        with urllib.request.urlopen(req, timeout=3) as resp:
            ms = int((time.time() - started) * 1000)
            return {"name": name, "url": url, "ok": resp.status == 200,
                    "status": resp.status, "ms": ms}
    except Exception as exc:  # noqa: BLE001 — любой сбой = недоступен
        ms = int((time.time() - started) * 1000)
        return {"name": name, "url": url, "ok": False,
                "status": str(exc)[:120], "ms": ms}


# --------------------------------------------------------------------------
# обзор: healthz + счётчики
# --------------------------------------------------------------------------

@app.get("/admin/api/overview")
def overview(admin: Dict[str, Any] = Depends(_require_admin)) -> Dict[str, Any]:
    services = [_probe(name, url) for name, url in HEALTH_TARGETS]
    conn = _auth_rows("SELECT COUNT(*) AS n FROM users")[0]["n"]
    sessions = _auth_rows(
        "SELECT COUNT(*) AS n FROM sessions "
        "WHERE expires_at > ? AND revoked_at IS NULL",
        (time.time(),))[0]["n"]
    orgs = _auth_rows("SELECT COUNT(*) AS n FROM organizations")[0]["n"]
    d = _db()
    def _count(sql: str) -> int:
        rows = d.query(sql)
        return int(rows[0].get("n") or 0) if rows else 0
    counts = {
        "users": conn,
        "active_sessions": sessions,
        "organizations": orgs,
        "projects": _count("SELECT COUNT(*) AS n FROM projects"),
        "files": _count("SELECT COUNT(*) AS n FROM files"),
        "orders_pending": _count(
            "SELECT COUNT(*) AS n FROM orders WHERE status = 'pending'"),
        "orders_paid": _count(
            "SELECT COUNT(*) AS n FROM orders WHERE status = 'paid'"),
        "pro_orgs": _count(
            "SELECT COUNT(*) AS n FROM entitlements "
            "WHERE pro IS TRUE"),
    }
    return {"services": services, "counts": counts,
            "system_org": admin["system_org"],
            "db_ok": True}


# --------------------------------------------------------------------------
# аккаунты
# --------------------------------------------------------------------------

@app.get("/admin/api/users")
def users_list(query: str = "",
               admin: Dict[str, Any] = Depends(_require_admin)) -> Dict[str, Any]:
    q = (query or "").strip()
    like = f"%{q}%"
    rows = _auth_rows(
        "SELECT id, email, name, phone, created_at, email_verified_at "
        "FROM users "
        "WHERE (? = '' OR email LIKE ? OR IFNULL(name, '') LIKE ?) "
        "ORDER BY created_at DESC LIMIT 100", (q, like, like))
    now = time.time()
    sessions = {r["user_id"]: r["n"] for r in _auth_rows(
        "SELECT user_id, COUNT(*) AS n FROM sessions "
        "WHERE expires_at > ? AND revoked_at IS NULL GROUP BY user_id",
        (now,))}
    orgs_by_user: Dict[str, List[str]] = {}
    for r in _auth_rows(
            "SELECT m.user_id, o.name AS org_name, m.role FROM memberships m "
            "JOIN organizations o ON o.id = m.org_id"):
        orgs_by_user.setdefault(r["user_id"], []).append(
            f"{r['org_name']} ({r['role']})")
    items = []
    for r in rows:
        items.append({
            "id": r["id"], "email": r["email"], "name": r["name"] or "",
            "phone": r["phone"] or "",
            "created_at": r["created_at"],
            "verified": bool(r["email_verified_at"]),
            "active_sessions": sessions.get(r["id"], 0),
            "orgs": orgs_by_user.get(r["id"], []),
        })
    return {"items": items, "count": len(items),
            "system_org": admin["system_org"]}


@app.post("/admin/api/users/{user_id}/revoke-sessions")
def users_revoke(user_id: str,
                 admin: Dict[str, Any] = Depends(_require_admin)) -> Dict[str, Any]:
    rows = _auth_rows("SELECT token_hash FROM sessions WHERE user_id = ?",
                      (user_id,))
    if not rows:
        return {"ok": True, "revoked": 0}
    conn = sqlite3.connect(f"file:{AUTH_DB_PATH}?mode=rw", uri=True,
                           timeout=10)
    try:
        cur = conn.execute("DELETE FROM sessions WHERE user_id = ?", (user_id,))
        conn.commit()
        revoked = cur.rowcount
    finally:
        conn.close()
    return {"ok": True, "revoked": int(revoked)}


@app.delete("/admin/api/users/{user_id}")
def users_delete(user_id: str,
                 admin: Dict[str, Any] = Depends(_require_admin)) -> Dict[str, Any]:
    """Удаление аккаунта. Нельзя удалить owner системной организации."""
    sys_id = admin["system_org"]["id"]
    owner_row = _auth_rows(
        "SELECT role FROM memberships WHERE user_id = ? AND org_id = ?",
        (user_id, sys_id))
    if owner_row and owner_row[0]["role"] == "owner":
        raise HTTPException(
            status_code=400,
            detail="Нельзя удалить владельца системной организации")
    user = _auth_rows("SELECT email FROM users WHERE id = ?", (user_id,))
    if not user:
        raise HTTPException(status_code=404, detail="Пользователь не найден")
    # Организации, созданные этим пользователем, где он — единственный член.
    orphan_orgs: List[str] = []
    for org in _auth_rows("SELECT id FROM organizations WHERE created_by = ?",
                          (user_id,)):
        n = _auth_rows("SELECT COUNT(*) AS n FROM memberships WHERE org_id = ?",
                       (org["id"],))[0]["n"]
        member = _auth_rows(
            "SELECT 1 AS x FROM memberships WHERE org_id = ? AND user_id = ?",
            (org["id"], user_id))
        if n <= 1 and member:
            orphan_orgs.append(org["id"])
    conn = sqlite3.connect(f"file:{AUTH_DB_PATH}?mode=rw", uri=True,
                           timeout=10)
    try:
        for sql, params in (
            ("DELETE FROM sessions WHERE user_id = ?", (user_id,)),
            ("DELETE FROM verify_codes WHERE user_id = ?", (user_id,)),
            ("DELETE FROM reset_codes WHERE user_id = ?", (user_id,)),
            ("DELETE FROM invites WHERE email = ?", (user[0]["email"],)),
            ("DELETE FROM memberships WHERE user_id = ?", (user_id,)),
        ):
            conn.execute(sql, params)
        for org_id in orphan_orgs:
            conn.execute("DELETE FROM memberships WHERE org_id = ?", (org_id,))
            conn.execute("DELETE FROM organizations WHERE id = ?", (org_id,))
        conn.execute("DELETE FROM users WHERE id = ?", (user_id,))
        conn.commit()
    finally:
        conn.close()
    return {"ok": True, "email": user[0]["email"],
            "deleted_organizations": len(orphan_orgs)}


# --------------------------------------------------------------------------
# доступы: системная организация
# --------------------------------------------------------------------------

@app.get("/admin/api/access")
def access_list(admin: Dict[str, Any] = Depends(_require_admin)) -> Dict[str, Any]:
    org = admin["system_org"]
    members = _auth_rows(
        "SELECT m.user_id, m.role, m.created_at, u.email, u.name "
        "FROM memberships m JOIN users u ON u.id = m.user_id "
        "WHERE m.org_id = ? ORDER BY m.created_at ASC", (org["id"],))
    return {"system_org": org, "members": members,
            "caller_role": admin["role"]}


@app.post("/admin/api/access")
def access_add(body: AccessIn,
               admin: Dict[str, Any] = Depends(_require_admin)) -> Dict[str, Any]:
    """Назначение роли через auth API (member/viewer/admin)."""
    org = admin["system_org"]
    status, payload = _auth_request(
        "POST", f"/auth/orgs/{org['id']}/members", token=admin["token"],
        body={"email": body.email, "role": body.role})
    if status not in (200, 201):
        raise HTTPException(status_code=status,
                            detail=(payload or {}).get("detail")
                            or "Не удалось добавить участника")
    return {"ok": True, **(payload if isinstance(payload, dict) else {})}


@app.delete("/admin/api/access/{user_id}")
def access_remove(user_id: str,
                  admin: Dict[str, Any] = Depends(_require_admin)) -> Dict[str, Any]:
    org = admin["system_org"]
    status, payload = _auth_request(
        "DELETE", f"/auth/orgs/{org['id']}/members/{user_id}",
        token=admin["token"])
    if status not in (200,):
        raise HTTPException(status_code=status,
                            detail=(payload or {}).get("detail")
                            or "Не удалось удалить участника")
    return {"ok": True}


# --------------------------------------------------------------------------
# подписки и заказы
# --------------------------------------------------------------------------

@app.get("/admin/api/subscriptions")
def subscriptions_list(admin: Dict[str, Any] = Depends(_require_admin)) -> Dict[str, Any]:
    d = _db()
    subs = d.query(
        "SELECT org_id, plan, status, current_period_end, "
        "cancel_at_period_end FROM subscriptions "
        "ORDER BY updated_at DESC LIMIT 200")
    ents = {r["org_id"]: r for r in d.query(
        "SELECT org_id, plan, status, pro, until FROM entitlements")}
    org_names = {r["id"]: r["name"] for r in _auth_rows(
        "SELECT id, name FROM organizations")}
    items = []
    seen = set()
    for s in subs:
        e = ents.get(s["org_id"], {})
        seen.add(s["org_id"])
        items.append({
            "org_id": s["org_id"],
            "org_name": org_names.get(s["org_id"], "—"),
            "plan": s["plan"], "status": s["status"],
            "period_end": s["current_period_end"],
            "cancel_at_period_end": bool(s["cancel_at_period_end"]),
            "pro": bool(e.get("pro")), "until": e.get("until"),
        })
    for org_id, e in ents.items():  # entitlements без подписки
        if org_id not in seen:
            items.append({
                "org_id": org_id,
                "org_name": org_names.get(org_id, "—"),
                "plan": e.get("plan"), "status": None,
                "period_end": None, "cancel_at_period_end": False,
                "pro": bool(e.get("pro")), "until": e.get("until"),
            })
    return {"items": items, "count": len(items)}


@app.post("/admin/api/subscriptions")
def subscriptions_action(body: SubscriptionActionIn,
                         admin: Dict[str, Any] = Depends(_require_admin)) -> Dict[str, Any]:
    """Ручное управление Pro: grant (+30/365 дней) | revoke.

    Пишет в subscriptions + entitlements (проекция, которую читают клиенты).
    Возврат реальных средств — только через кабинет ЮKassa.
    """
    org_id = body.org_id
    now = time.time()
    now_iso = _to_iso(now)
    d = _db()
    if body.action == "revoke":
        with d.tx() as tx:
            tx.exec(
                "UPDATE subscriptions SET status = 'canceled', updated_at = ? "
                "WHERE org_id = ?", (now_iso, org_id))
            tx.exec(
                "UPDATE entitlements SET pro = FALSE, status = 'free', "
                "plan = 'free', until = NULL, updated_at = ? "
                "WHERE org_id = ?", (now_iso, org_id))
        return {"ok": True, "action": "revoke", "org_id": org_id,
                "note": "Pro отозван; возврат средств — в кабинете ЮKassa"}
    days = 30 if body.plan == "month" else 365
    until = _to_iso(now + days * 86400)
    with d.tx() as tx:
        existing = tx.query("SELECT id FROM subscriptions WHERE org_id = ?",
                            (org_id,))
        if existing:
            tx.exec(
                "UPDATE subscriptions SET plan = ?, status = 'active', "
                "current_period_start = ?, current_period_end = ?, "
                "cancel_at_period_end = FALSE, updated_at = ? "
                "WHERE org_id = ?",
                (body.plan, now_iso, until, now_iso, org_id))
        else:
            tx.exec(
                "INSERT INTO subscriptions (id, org_id, plan, status, "
                "current_period_start, current_period_end, "
                "cancel_at_period_end, created_at, updated_at) "
                "VALUES (?, ?, ?, 'active', ?, ?, FALSE, ?, ?)",
                (secrets.token_hex(16), org_id, body.plan,
                 now_iso, until, now_iso, now_iso))
        ent = tx.query("SELECT id FROM entitlements WHERE org_id = ?",
                       (org_id,))
        if ent:
            tx.exec(
                "UPDATE entitlements SET plan = ?, status = 'active', "
                "pro = TRUE, until = ?, updated_at = ? WHERE org_id = ?",
                (body.plan, until, now_iso, org_id))
        else:
            tx.exec(
                "INSERT INTO entitlements (id, org_id, plan, status, pro, "
                "features, until, updated_at) "
                "VALUES (?, ?, ?, 'active', TRUE, '{}', ?, ?)",
                (secrets.token_hex(16), org_id, body.plan, until, now_iso))
    return {"ok": True, "action": "grant", "org_id": org_id,
            "plan": body.plan, "until": until}


@app.get("/admin/api/orders")
def orders_list(status: str = "",
                admin: Dict[str, Any] = Depends(_require_admin)) -> Dict[str, Any]:
    d = _db()
    q = (status or "").strip()
    if q:
        rows = d.query(
            "SELECT id, org_id, plan, amount_rub, status, created_at, "
            "paid_at, refunded_at FROM orders WHERE status = ? "
            "ORDER BY created_at DESC LIMIT 100", (q,))
    else:
        rows = d.query(
            "SELECT id, org_id, plan, amount_rub, status, created_at, "
            "paid_at, refunded_at FROM orders "
            "ORDER BY created_at DESC LIMIT 100")
    org_names = {r["id"]: r["name"] for r in _auth_rows(
        "SELECT id, name FROM organizations")}
    for r in rows:
        r["org_name"] = org_names.get(r["org_id"], "—")
    return {"items": rows, "count": len(rows)}


# --------------------------------------------------------------------------
# БД: read-only просмотр
# --------------------------------------------------------------------------

@app.get("/admin/api/db/tables")
def db_tables(admin: Dict[str, Any] = Depends(_require_admin)) -> Dict[str, Any]:
    d = _db()
    items = []
    for t in DB_TABLES:
        rows = d.query(f"SELECT COUNT(*) AS n FROM {t}")
        items.append({"table": t, "rows": int(rows[0].get("n") or 0)
                      if rows else 0})
    return {"tables": items, "note": "read-only, whitelist"}


@app.get("/admin/api/db/{table}")
def db_table(table: str, limit: int = 50, offset: int = 0,
             admin: Dict[str, Any] = Depends(_require_admin)) -> Dict[str, Any]:
    if table not in DB_TABLES:
        raise HTTPException(status_code=404, detail="Таблица не в whitelist")
    limit = max(1, min(int(limit), 200))
    offset = max(0, int(offset))
    d = _db()
    rows = d.query(f"SELECT * FROM {table} ORDER BY 1 LIMIT ? OFFSET ?",
                   (limit, offset))
    return {"table": table, "limit": limit, "offset": offset,
            "rows": rows, "count": len(rows)}


# --------------------------------------------------------------------------
# healthz и HTML
# --------------------------------------------------------------------------

@app.get("/healthz")
def healthz() -> Dict[str, Any]:
    return {"status": "ok", "service": "admin",
            "auth_url": AUTH_URL, "db": "configured" if db else "missing",
            "auth_db": AUTH_DB_PATH}


@app.get("/admin", include_in_schema=False)
@app.get("/admin/", include_in_schema=False)
def index() -> HTMLResponse:
    if not INDEX_PATH.exists():
        return HTMLResponse("<h1>admin panel: index.html не найден</h1>",
                            status_code=500)
    return HTMLResponse(INDEX_PATH.read_text(encoding="utf-8"))
