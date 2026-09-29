# -*- coding: utf-8 -*-
"""Тесты админ-панели (services/admin).

Гейт по роли owner/admin в системной (первой) организации, аккаунты
(revoke/delete с каскадом), доступы через auth API, подписки grant/revoke,
read-only просмотр БД, healthz-агрегация. HTTP к auth подменяется фейком;
auth.db и «PG» — временные SQLite-файлы.
"""
import os
import sqlite3
import sys
import tempfile
from pathlib import Path

import pytest

_TMP = tempfile.mkdtemp(prefix="pp_admin_test_")
# Глобальный env НЕ трогаем (чужие сьюты в общем процессе читают DB_URL
# динамически): пути подставляет fixture в main-глобалы напрямую.
os.environ["AUTH_URL"] = "http://auth.test:8121"
PANEL_DB = str(Path(_TMP) / "panel.db")
AUTH_DB = str(Path(_TMP) / "auth.db")

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from fastapi.testclient import TestClient  # noqa: E402

import admin_app.main as main  # noqa: E402

client = TestClient(main.app)

SYS_ORG = "org-system"
OTHER_ORG = "org-other"


def _init_auth_db() -> None:
    conn = sqlite3.connect(main.AUTH_DB_PATH)
    conn.executescript(
        """
        CREATE TABLE users (
            id TEXT PRIMARY KEY, email TEXT NOT NULL UNIQUE,
            password_hash TEXT NOT NULL, name TEXT, phone TEXT,
            created_at REAL NOT NULL, updated_at REAL,
            email_verified_at REAL, phone_verified_at REAL);
        CREATE TABLE organizations (
            id TEXT PRIMARY KEY, name TEXT NOT NULL, created_by TEXT,
            created_at REAL NOT NULL, updated_at REAL);
        CREATE TABLE memberships (
            id TEXT PRIMARY KEY, org_id TEXT NOT NULL, user_id TEXT NOT NULL,
            role TEXT NOT NULL, invited_by TEXT, created_at REAL NOT NULL,
            UNIQUE (org_id, user_id));
        CREATE TABLE sessions (
            token_hash TEXT PRIMARY KEY, user_id TEXT NOT NULL, device_id TEXT,
            created_at REAL NOT NULL, expires_at REAL NOT NULL,
            revoked_at REAL, meta TEXT);
        CREATE TABLE invites (
            id TEXT PRIMARY KEY, org_id TEXT NOT NULL, email TEXT NOT NULL,
            role TEXT NOT NULL, code_hash TEXT NOT NULL, invited_by TEXT,
            created_at REAL NOT NULL, expires_at REAL NOT NULL,
            accepted_at REAL);
        CREATE TABLE reset_codes (
            email TEXT NOT NULL, user_id TEXT, code_hash TEXT NOT NULL,
            created_at REAL NOT NULL, expires_at REAL NOT NULL,
            used INTEGER NOT NULL DEFAULT 0);
        CREATE TABLE verify_codes (
            id TEXT PRIMARY KEY, channel TEXT NOT NULL, dest TEXT NOT NULL,
            user_id TEXT NOT NULL, code_hash TEXT NOT NULL,
            created_at REAL NOT NULL, expires_at REAL NOT NULL);
        """
    )
    conn.execute(
        "INSERT INTO organizations (id, name, created_by, created_at) "
        "VALUES (?, ?, ?, ?)", (SYS_ORG, "Системная", "u-admin", 100.0))
    conn.execute(
        "INSERT INTO organizations (id, name, created_by, created_at) "
        "VALUES (?, ?, ?, ?)", (OTHER_ORG, "Чужая", "u-user", 200.0))
    for uid, email, name in (
        ("u-admin", "admin@example.com", "Админ"),
        ("u-user", "user@example.com", "Юзер"),
        ("u-victim", "victim@example.com", "Жертва"),
    ):
        conn.execute(
            "INSERT INTO users (id, email, password_hash, name, created_at, "
            "email_verified_at) VALUES (?, ?, 'x', ?, ?, 1.0)",
            (uid, email, name, 1000.0))
    conn.execute(
        "INSERT INTO memberships (id, org_id, user_id, role, created_at) "
        "VALUES ('m1', ?, 'u-admin', 'owner', 100.0)", (SYS_ORG,))
    conn.execute(
        "INSERT INTO memberships (id, org_id, user_id, role, created_at) "
        "VALUES ('m2', ?, 'u-user', 'owner', 200.0)", (OTHER_ORG,))
    conn.execute(
        "INSERT INTO memberships (id, org_id, user_id, role, created_at) "
        "VALUES ('m3', ?, 'u-victim', 'member', 300.0)", (SYS_ORG,))
    import time as _t
    conn.execute(
        "INSERT INTO sessions (token_hash, user_id, created_at, expires_at) "
        "VALUES ('h1', 'u-victim', ?, ?)", (_t.time(), _t.time() + 3600))
    conn.commit()
    conn.close()


def _init_panel_db() -> None:
    conn = sqlite3.connect(main.db.db_url)
    conn.executescript(
        """
        CREATE TABLE plans (plan TEXT PRIMARY KEY, title TEXT,
            amount_rub INTEGER DEFAULT 0, days INTEGER DEFAULT 0);
        CREATE TABLE projects (id TEXT PRIMARY KEY, name TEXT,
            org_id TEXT, created_at TEXT);
        CREATE TABLE files (id TEXT PRIMARY KEY, org_id TEXT, name TEXT);
        CREATE TABLE file_versions (id TEXT PRIMARY KEY, file_id TEXT);
        CREATE TABLE reports (id TEXT PRIMARY KEY, project_id TEXT,
            fmt TEXT);
        CREATE TABLE orders (
            id TEXT PRIMARY KEY, org_id TEXT NOT NULL, user_id TEXT,
            plan TEXT, amount_rub INTEGER, currency TEXT DEFAULT 'RUB',
            status TEXT DEFAULT 'pending', provider_order_id TEXT,
            confirmation_url TEXT, created_at TEXT, paid_at TEXT,
            refunded_at TEXT);
        CREATE TABLE transactions (
            id TEXT PRIMARY KEY, order_id TEXT, provider_payment_id TEXT,
            event_type TEXT, amount_rub INTEGER DEFAULT 0,
            currency TEXT DEFAULT 'RUB', status TEXT, received_at TEXT);
        CREATE TABLE subscriptions (
            id TEXT PRIMARY KEY, org_id TEXT NOT NULL UNIQUE,
            plan TEXT DEFAULT 'free', status TEXT DEFAULT 'trialing',
            trial_started_at TEXT, current_period_start TEXT,
            current_period_end TEXT, cancel_at_period_end INTEGER DEFAULT 0,
            provider_subscription_id TEXT, created_at TEXT, updated_at TEXT);
        CREATE TABLE entitlements (
            id TEXT PRIMARY KEY, org_id TEXT NOT NULL UNIQUE,
            plan TEXT DEFAULT 'free', status TEXT DEFAULT 'free',
            pro INTEGER DEFAULT 0, features TEXT DEFAULT '{}',
            until TEXT, updated_at TEXT);
        """
    )
    conn.execute(
        "INSERT INTO orders (id, org_id, plan, amount_rub, status, "
        "created_at) VALUES ('ord1', ?, 'month', 5000, 'paid', "
        "'2026-09-29T10:00:00Z')", (OTHER_ORG,))
    conn.commit()
    conn.close()


FAKE_TOKENS = {
    "tok-admin": {"sub": "u-admin", "email": "admin@example.com",
                  "orgs": [{"org_id": SYS_ORG, "role": "owner"}]},
    "tok-stranger": {"sub": "u-user", "email": "user@example.com",
                     "orgs": [{"org_id": OTHER_ORG, "role": "owner"}]},
}
_calls = []


def _fake_auth_request(method, path, token=None, body=None, timeout=10.0):
    _calls.append((method, path, token, body))
    if path == "/auth/verify":
        claims = FAKE_TOKENS.get(token or "")
        if not claims:
            return 401, {"detail": "Сессия недействительна"}
        return 200, dict(claims)
    if path == "/auth/login":
        email = (body or {}).get("email")
        if email == "admin@example.com":
            return 200, {"token": "tok-admin"}
        if email == "user@example.com":
            return 200, {"token": "tok-stranger"}
        return 401, {"detail": "Неверный email или пароль"}
    if path.endswith("/members") and method == "POST":
        return 201, {"status": "added",
                     "member": {"user_id": "u-new",
                                "role": (body or {}).get("role")}}
    if method == "DELETE" and "/members/" in path:
        return 200, {"ok": True}
    return 404, {"detail": "не найдено"}


@pytest.fixture(autouse=True)
def _env(monkeypatch):
    for target in (PANEL_DB, AUTH_DB):
        try:
            os.remove(target)
        except FileNotFoundError:
            pass
    monkeypatch.setattr(main, "db", main.AdminDb(PANEL_DB))
    monkeypatch.setattr(main, "AUTH_DB_PATH", AUTH_DB)
    _init_auth_db()
    _init_panel_db()
    monkeypatch.setattr(main, "_auth_request", _fake_auth_request)
    # Пробы healthz — на заведомо закрытый локальный порт (мгновенный
    # connection refused вместо DNS-таймаутов на имена k8s-сервисов).
    monkeypatch.setattr(main, "HEALTH_TARGETS",
                        [("stub", "http://127.0.0.1:9/healthz")])
    _calls.clear()
    yield


def _h(token: str) -> dict:
    return {"Authorization": f"Bearer {token}"}


def test_healthz():
    r = client.get("/healthz")
    assert r.status_code == 200
    assert r.json()["service"] == "admin"
    assert r.json()["db"] == "configured"


def test_login_gates_by_system_org():
    # Владелец системной организации — ок.
    r = client.post("/admin/api/login",
                    json={"email": "admin@example.com", "password": "x"})
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["token"] == "tok-admin"
    assert body["role"] == "owner"
    assert body["system_org"]["id"] == SYS_ORG
    # Чужой owner (другая организация) — 403.
    r = client.post("/admin/api/login",
                    json={"email": "user@example.com", "password": "y"})
    assert r.status_code == 403
    # Неверный пароль от auth — его статус.
    r = client.post("/admin/api/login",
                    json={"email": "nobody@example.com", "password": "z"})
    assert r.status_code == 401
    # Без токена — 401.
    assert client.get("/admin/api/overview").status_code == 401
    # Чужой токен — 403.
    assert client.get("/admin/api/overview",
                      headers=_h("tok-stranger")).status_code == 403


def test_overview_counts_and_services():
    r = client.get("/admin/api/overview", headers=_h("tok-admin"))
    assert r.status_code == 200, r.text
    data = r.json()
    assert data["counts"]["users"] == 3
    assert data["counts"]["active_sessions"] == 1
    assert data["counts"]["orders_paid"] == 1
    # healthz-пробы недоступных в тесте адресов — не падают, помечены down.
    assert all("name" in s and "ok" in s for s in data["services"])
    assert len(data["services"]) == len(main.HEALTH_TARGETS)


def test_users_list_search_revoke_delete():
    r = client.get("/admin/api/users?query=victim",
                   headers=_h("tok-admin"))
    assert r.status_code == 200
    items = r.json()["items"]
    assert len(items) == 1
    victim = items[0]
    assert victim["email"] == "victim@example.com"
    assert victim["active_sessions"] == 1
    assert victim["orgs"] == ["Системная (member)"]

    # Отзыв сессий.
    r = client.post(f"/admin/api/users/{victim['id']}/revoke-sessions",
                    headers=_h("tok-admin"))
    assert r.status_code == 200 and r.json()["revoked"] == 1
    r = client.get("/admin/api/users?query=victim",
                   headers=_h("tok-admin"))
    assert r.json()["items"][0]["active_sessions"] == 0

    # Нельзя удалить owner системной организации.
    r = client.delete("/admin/api/users/u-admin", headers=_h("tok-admin"))
    assert r.status_code == 400

    # Обычный пользователь удаляется (каскад: сессии/членства/коды).
    r = client.delete(f"/admin/api/users/{victim['id']}",
                      headers=_h("tok-admin"))
    assert r.status_code == 200, r.text
    assert r.json()["deleted_organizations"] == 0
    conn = sqlite3.connect(main.AUTH_DB_PATH)
    left = conn.execute("SELECT COUNT(*) FROM users WHERE id = 'u-victim'") \
        .fetchone()[0]
    m = conn.execute(
        "SELECT COUNT(*) FROM memberships WHERE user_id = 'u-victim'") \
        .fetchone()[0]
    s = conn.execute(
        "SELECT COUNT(*) FROM sessions WHERE user_id = 'u-victim'") \
        .fetchone()[0]
    conn.close()
    assert left == 0 and m == 0 and s == 0


def test_access_add_and_remove_proxies_auth():
    r = client.get("/admin/api/access", headers=_h("tok-admin"))
    assert r.status_code == 200
    data = r.json()
    assert data["system_org"]["id"] == SYS_ORG
    emails = [m["email"] for m in data["members"]]
    assert "admin@example.com" in emails and "victim@example.com" in emails

    r = client.post("/admin/api/access",
                    json={"email": "new@example.com", "role": "admin"},
                    headers=_h("tok-admin"))
    assert r.status_code == 200 and r.json()["status"] == "added"
    assert ("POST", f"/auth/orgs/{SYS_ORG}/members", "tok-admin",
            {"email": "new@example.com", "role": "admin"}) in _calls

    # Недопустимая роль — 422 до ухода в auth.
    r = client.post("/admin/api/access",
                    json={"email": "new@example.com", "role": "owner"},
                    headers=_h("tok-admin"))
    assert r.status_code == 422

    r = client.delete("/admin/api/access/u-victim", headers=_h("tok-admin"))
    assert r.status_code == 200
    assert any(c[0] == "DELETE" and c[1].endswith("/members/u-victim")
               for c in _calls)


def test_subscriptions_grant_and_revoke():
    # grant: появляется подписка + entitlements pro.
    r = client.post("/admin/api/subscriptions",
                    json={"org_id": OTHER_ORG, "action": "grant",
                          "plan": "month"},
                    headers=_h("tok-admin"))
    assert r.status_code == 200, r.text
    assert r.json()["until"].endswith("Z")
    conn = sqlite3.connect(main.db.db_url)
    sub = conn.execute("SELECT status, plan FROM subscriptions WHERE org_id=?",
                       (OTHER_ORG,)).fetchone()
    ent = conn.execute(
        "SELECT pro, status, until FROM entitlements WHERE org_id=?",
        (OTHER_ORG,)).fetchone()
    conn.close()
    assert sub == ("active", "month")
    assert ent[0] == 1 and ent[1] == "active" and ent[2]

    r = client.get("/admin/api/subscriptions", headers=_h("tok-admin"))
    assert r.status_code == 200
    row = next(x for x in r.json()["items"] if x["org_id"] == OTHER_ORG)
    assert row["pro"] is True and row["org_name"] == "Чужая"

    # revoke: pro снимается.
    r = client.post("/admin/api/subscriptions",
                    json={"org_id": OTHER_ORG, "action": "revoke"},
                    headers=_h("tok-admin"))
    assert r.status_code == 200
    conn = sqlite3.connect(main.db.db_url)
    ent = conn.execute("SELECT pro, status FROM entitlements WHERE org_id=?",
                       (OTHER_ORG,)).fetchone()
    conn.close()
    assert ent == (0, "free")


def test_orders_list():
    r = client.get("/admin/api/orders", headers=_h("tok-admin"))
    assert r.status_code == 200
    items = r.json()["items"]
    assert len(items) == 1
    assert items[0]["org_name"] == "Чужая"
    r = client.get("/admin/api/orders?status=pending",
                   headers=_h("tok-admin"))
    assert r.json()["items"] == []


def test_db_tables_and_whitelist():
    r = client.get("/admin/api/db/tables", headers=_h("tok-admin"))
    assert r.status_code == 200
    names = [t["table"] for t in r.json()["tables"]]
    assert set(names) == set(main.DB_TABLES)
    r = client.get("/admin/api/db/projects", headers=_h("tok-admin"))
    assert r.status_code == 200
    # Вне whitelist — 404.
    r = client.get("/admin/api/db/users", headers=_h("tok-admin"))
    assert r.status_code == 404
    r = client.get("/admin/api/db/sessions", headers=_h("tok-admin"))
    assert r.status_code == 404


def test_index_html_served():
    r = client.get("/admin/")
    assert r.status_code == 200
    assert "Админ-панель" in r.text
