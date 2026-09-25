# -*- coding: utf-8 -*-
"""Тесты микросервиса авторизации (SaaS-модель).

Проверяем контракт System Design v1 §12.2 / §13.1: организации и роли,
мультисессии (лимит устройств 1/1 удалён), forgot/reset без dev_code,
отзыв сессий, /auth/verify для внутренних сервисов, миграция legacy-БД.
"""
import os
import sqlite3
import sys
import tempfile
import time
from pathlib import Path

import pytest

# Изолированная БД до импорта приложения.
_tmp = tempfile.mkdtemp(prefix="pp_auth_test_")
os.environ["PP_DATA_DIR"] = _tmp
os.environ["PP_AUTH_SECRET"] = "test-secret-0123456789abcdef"
os.environ["PP_TOKEN_TTL"] = "1"
os.environ["PP_DEFAULT_ORG"] = "1"
os.environ.pop("PP_SMTP_HOST", None)

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from fastapi.testclient import TestClient  # noqa: E402

from auth_app.main import app  # noqa: E402
from auth_app.main import _session_claims  # noqa: E402

client = TestClient(app)

_counter = {"n": 0}


@pytest.fixture(autouse=True)
def _pin_env():
    """Пиннинг окружения перед каждым тестом.

    pytest импортирует все собранные модули до запуска: другой набор
    (services/payments) пишет PP_DATA_DIR в os.environ при импорте и затирает
    наш каталог — хелперы ниже читают os.environ во время теста.
    """
    os.environ["PP_DATA_DIR"] = _tmp
    os.environ["PP_AUTH_SECRET"] = "test-secret-0123456789abcdef"
    os.environ["PP_TOKEN_TTL"] = "1"
    os.environ["PP_DEFAULT_ORG"] = "1"
    os.environ.pop("PP_SMTP_HOST", None)
    yield


def _email(tag: str) -> str:
    _counter["n"] += 1
    return f"{tag}-{_counter['n']}@example.com"


def _auth(token: str) -> dict:
    return {"Authorization": f"Bearer {token}"}


def _register(email: str, password: str = "secret1", **extra) -> dict:
    r = client.post("/auth/register",
                    json={"email": email, "password": password, **extra})
    assert r.status_code == 201, r.text
    return r.json()


def test_healthz():
    r = client.get("/healthz")
    assert r.status_code == 200
    body = r.json()
    assert body["sessions"] == "server-side"
    assert body["device_policy"] == "multi"
    assert body["device_limit"] is None
    assert body["multitenant"] is True
    assert set(body["roles"]) == {"owner", "admin", "member", "viewer"}


def test_register_with_org_name_creates_owner_membership():
    data = _register(_email("org"), org_name="Типография «Тест»")
    assert data["token"]
    assert data["user"]["email"].startswith("org-")
    assert len(data["orgs"]) == 1
    org = data["orgs"][0]
    assert org["role"] == "owner" and org["org_id"]

    me = client.get("/auth/me", headers=_auth(data["token"]))
    assert me.status_code == 200
    body = me.json()
    assert body["user"]["id"] == data["user"]["id"]
    assert body["orgs"] == [{"org_id": org["org_id"], "role": "owner"}]
    assert body["memberships"][0]["name"] == "Типография «Тест»"

    orgs = client.get("/auth/orgs", headers=_auth(data["token"]))
    assert orgs.status_code == 200
    assert orgs.json()["orgs"][0]["role"] == "owner"


def test_register_without_org_name_gets_personal_org():
    data = _register(_email("personal"))
    assert len(data["orgs"]) == 1
    assert data["orgs"][0]["role"] == "owner"


def test_register_duplicate_email_409_and_bad_input():
    email = _email("dup")
    _register(email)
    r = client.post("/auth/register",
                    json={"email": email, "password": "secret1"})
    assert r.status_code == 409

    r = client.post("/auth/register",
                    json={"email": "not-an-email", "password": "secret1"})
    assert r.status_code == 422
    r = client.post("/auth/register",
                    json={"email": "a@b.co", "password": "123"})
    assert r.status_code == 422


def test_login_returns_orgs_and_multiple_sessions_coexist():
    """Лимит устройств 1/1 удалён: вход со второго device_id не вытесняет первый."""
    email = _email("multi")
    first = _register(email, org_name="Мульти")
    token_a = first["token"]

    r = client.post("/auth/login", json={
        "email": email, "password": "secret1", "device_id": "dev-b"})
    assert r.status_code == 200, r.text
    token_b = r.json()["token"]
    assert r.json()["orgs"] == first["orgs"]

    # Обе сессии живы.
    assert client.get("/auth/me", headers=_auth(token_a)).status_code == 200
    assert client.get("/auth/me", headers=_auth(token_b)).status_code == 200

    r = client.get("/auth/sessions", headers=_auth(token_b))
    assert r.status_code == 200
    items = r.json()["sessions"]
    assert len(items) == 2
    assert sum(1 for s in items if s["current"]) == 1

    # Совместимый /auth/devices возвращает тот же список без лимита.
    r = client.get("/auth/devices", headers=_auth(token_b))
    assert r.status_code == 200
    assert len(r.json()["devices"]) == 2
    assert r.json()["device_policy"] == "multi"

    # Вход без device_id тоже работает (device_id необязателен).
    r = client.post("/auth/login", json={"email": email,
                                         "password": "secret1"})
    assert r.status_code == 200

    # Неверный пароль.
    r = client.post("/auth/login", json={"email": email,
                                         "password": "wrong!"})
    assert r.status_code == 401


def test_session_revoke_by_id():
    email = _email("revoke")
    token_a = _register(email)["token"]
    token_b = client.post("/auth/login", json={
        "email": email, "password": "secret1", "device_id": "dev-b"}).json()["token"]

    r = client.get("/auth/sessions", headers=_auth(token_a))
    other = next(s for s in r.json()["sessions"] if not s["current"])
    r = client.post(f"/auth/sessions/{other['id']}/revoke",
                    headers=_auth(token_a))
    assert r.status_code == 200
    assert client.get("/auth/me", headers=_auth(token_b)).status_code == 401
    assert client.get("/auth/me", headers=_auth(token_a)).status_code == 200

    r = client.post("/auth/sessions/deadbeefdeadbeef/revoke",
                    headers=_auth(token_a))
    assert r.status_code == 404


def test_logout_revokes_only_current_session():
    email = _email("logout")
    token_a = _register(email)["token"]
    token_b = client.post("/auth/login", json={
        "email": email, "password": "secret1"}).json()["token"]

    r = client.post("/auth/logout", headers=_auth(token_a))
    assert r.status_code == 200 and r.json()["ok"] is True
    assert client.get("/auth/me", headers=_auth(token_a)).status_code == 401
    assert client.get("/auth/me", headers=_auth(token_b)).status_code == 200


def test_create_org_and_roles():
    email = _email("orgs")
    token = _register(email)["token"]
    r = client.post("/auth/orgs", json={"name": "Вторая типография"},
                    headers=_auth(token))
    assert r.status_code == 201, r.text
    org_id = r.json()["org_id"]
    assert r.json()["role"] == "owner"

    r = client.get("/auth/orgs", headers=_auth(token))
    assert len(r.json()["orgs"]) == 2

    # Членство в БД: роль owner записана в memberships.
    conn = sqlite3.connect(str(Path(os.environ["PP_DATA_DIR"]) / "auth.db"))
    row = conn.execute(
        "SELECT role FROM memberships WHERE org_id = ?", (org_id,)).fetchone()
    conn.close()
    assert row[0] == "owner"

    r = client.post("/auth/orgs", json={"name": " "}, headers=_auth(token))
    assert r.status_code == 422
    r = client.post("/auth/orgs", json={"name": "x"})
    assert r.status_code == 401


def test_org_membership_roles_enforced_by_db():
    """Роли owner/admin/member/viewer хранятся в memberships (модель тенантов)."""
    email_a, email_b = _email("owner"), _email("viewer")
    owner = _register(email_a, org_name="Тенант")
    viewer = _register(email_b)
    org_id = owner["orgs"][0]["org_id"]

    conn = sqlite3.connect(str(Path(os.environ["PP_DATA_DIR"]) / "auth.db"))
    conn.execute(
        "INSERT INTO memberships (id, org_id, user_id, role, invited_by, "
        "created_at) VALUES (?, ?, ?, ?, ?, ?)",
        ("m-" + viewer["user"]["id"], org_id, viewer["user"]["id"], "viewer",
         owner["user"]["id"], time.time()))
    conn.commit()
    conn.close()

    r = client.get("/auth/me", headers=_auth(viewer["token"]))
    assert {"org_id": org_id, "role": "viewer"} in r.json()["orgs"]

    r = client.get("/auth/me", headers=_auth(owner["token"]))
    assert {"org_id": org_id, "role": "owner"} in r.json()["orgs"]


def test_register_without_org_when_default_org_disabled():
    """PP_DEFAULT_ORG=0: регистрация без org_name → пользователь без организации."""
    import subprocess
    empty_dir = tempfile.mkdtemp(prefix="pp_auth_noorg_")
    env = dict(os.environ, PP_DATA_DIR=empty_dir, PP_DEFAULT_ORG="0")
    code = (
        "import os, tempfile;"
        "from pathlib import Path;"
        "os.environ['PP_DATA_DIR']=tempfile.mkdtemp(prefix='pp_auth_noorg_app_');"
        "from fastapi.testclient import TestClient;"
        "from auth_app.main import app;"
        "c = TestClient(app);"
        "r = c.post('/auth/register', json={'email':'solo@example.com',"
        "'password':'secret1'});"
        "print(r.status_code, r.json()['orgs']);"
        "r2 = c.post('/auth/register', json={'email':'team@example.com',"
        "'password':'secret1','org_name':'Team'});"
        "print(r2.status_code, len(r2.json()['orgs']), r2.json()['orgs'][0]['role']);"
    )
    out = subprocess.run([sys.executable, "-c", code], cwd=str(ROOT), env=env,
                         capture_output=True, text=True)
    assert out.returncode == 0, out.stderr
    lines = out.stdout.strip().splitlines()
    assert lines[0] == "201 []"          # пользователь без организации
    assert lines[1] == "201 1 owner"     # явная организация — owner


def test_forgot_never_returns_code_and_reset_revokes_all_sessions():
    email = _email("reset")
    old_token = _register(email)["token"]
    other_token = client.post("/auth/login", json={
        "email": email, "password": "secret1",
        "device_id": "dev-2"}).json()["token"]

    # Код никогда не возвращается в ответе (в т.ч. без SMTP).
    r = client.post("/auth/forgot", json={"email": email})
    assert r.status_code == 200
    assert r.json() == {"ok": True}

    # Код есть в БД, но только в виде sha256.
    conn = sqlite3.connect(str(Path(os.environ["PP_DATA_DIR"]) / "auth.db"))
    row = conn.execute(
        "SELECT code_hash, used, expires_at FROM reset_codes "
        "WHERE email = ?", (email,)).fetchone()
    conn.close()
    assert row is not None and len(row[0]) == 64 and row[1] == 0
    assert row[2] > time.time()

    # Неверный код — 400.
    r = client.post("/auth/reset", json={
        "email": email, "code": "000000", "new_password": "new-pass1"})
    assert r.status_code == 400

    # Несуществующий пользователь — 404.
    r = client.post("/auth/reset", json={
        "email": _email("ghost"), "code": "000000",
        "new_password": "new-pass1"})
    assert r.status_code == 404


def test_reset_flow_with_code_from_db():
    """Полный поток сброса: код берём из БД через прямой перебор невозможен —
    поэтому подменяем код известным значением (sha256), как это делает SMTP."""
    email = _email("reset2")
    token_a = _register(email)["token"]
    token_b = client.post("/auth/login", json={
        "email": email, "password": "secret1"}).json()["token"]

    assert client.post("/auth/forgot",
                       json={"email": email}).json() == {"ok": True}

    # Эмулируем письмо: переписываем code_hash на хеш известного кода.
    import hashlib
    known = "123456"
    known_hash = hashlib.sha256(known.encode("utf-8")).hexdigest()
    conn = sqlite3.connect(str(Path(os.environ["PP_DATA_DIR"]) / "auth.db"))
    conn.execute("UPDATE reset_codes SET code_hash = ? WHERE email = ?",
                 (known_hash, email))
    conn.commit()
    conn.close()

    r = client.post("/auth/reset", json={
        "email": email, "code": known, "new_password": "new-pass1"})
    assert r.status_code == 200, r.text

    # Все сессии пользователя отозваны.
    assert client.get("/auth/me", headers=_auth(token_a)).status_code == 401
    assert client.get("/auth/me", headers=_auth(token_b)).status_code == 401

    # Старый пароль не подходит, новый — да; организации сохранились.
    assert client.post("/auth/login", json={
        "email": email, "password": "secret1"}).status_code == 401
    r = client.post("/auth/login", json={"email": email,
                                         "password": "new-pass1"})
    assert r.status_code == 200
    assert len(r.json()["orgs"]) == 1

    # Код одноразовый: строка удалена после использования.
    conn = sqlite3.connect(str(Path(os.environ["PP_DATA_DIR"]) / "auth.db"))
    left = conn.execute("SELECT COUNT(*) FROM reset_codes WHERE email = ?",
                        (email,)).fetchone()[0]
    conn.close()
    assert left == 0

    # Повторное использование того же кода — 400.
    r = client.post("/auth/reset", json={
        "email": email, "code": known, "new_password": "new-pass2"})
    assert r.status_code == 400


def test_forgot_unknown_email_same_answer():
    r = client.post("/auth/forgot", json={"email": _email("ghost")})
    assert r.status_code == 200
    assert r.json() == {"ok": True}  # без dev_hint и без кода


def test_verify_endpoint_returns_orgs():
    email = _email("ver")
    data = _register(email, org_name="Verify Org")
    r = client.post("/auth/verify", headers=_auth(data["token"]))
    assert r.status_code == 200
    body = r.json()
    assert body["sub"] == data["user"]["id"]
    assert body["email"] == email
    assert body["orgs"] == data["orgs"]

    assert client.post("/auth/verify",
                       headers=_auth("bogus")).status_code == 401
    assert client.post("/auth/verify").status_code == 401


def test_verify_rejects_expired_and_revoked_sessions():
    email = _email("exp")
    token = _register(email)["token"]
    with pytest.raises(ValueError):
        _session_claims("no-such-token")

    conn = sqlite3.connect(str(Path(os.environ["PP_DATA_DIR"]) / "auth.db"))
    conn.execute("UPDATE sessions SET expires_at = ? WHERE user_id = ?",
                 (time.time() - 10, _user_id(email)))
    conn.commit()
    conn.close()
    assert client.get("/auth/me", headers=_auth(token)).status_code == 401


def _user_id(email: str) -> str:
    conn = sqlite3.connect(str(Path(os.environ["PP_DATA_DIR"]) / "auth.db"))
    row = conn.execute("SELECT id FROM users WHERE email = ?",
                       (email,)).fetchone()
    conn.close()
    assert row is not None
    return row[0]


def test_me_without_token():
    assert client.get("/auth/me").status_code == 401
    assert client.get("/auth/sessions").status_code == 401
    assert client.get("/auth/devices").status_code == 401


def test_password_hash_format_and_iterations():
    """Инвариант N-5: pbkdf2_hmac sha256 200k, salt$digest_hex."""
    email = _email("hash")
    _register(email, password="secret1")
    conn = sqlite3.connect(str(Path(os.environ["PP_DATA_DIR"]) / "auth.db"))
    stored = conn.execute("SELECT password_hash FROM users WHERE email = ?",
                          (email,)).fetchone()[0]
    conn.close()
    salt, digest = stored.split("$", 1)
    assert len(salt) == 32 and len(digest) == 64
    import hashlib
    assert hashlib.pbkdf2_hmac("sha256", b"secret1", bytes.fromhex(salt),
                               200_000).hex() == digest


def test_session_row_stores_only_sha256():
    email = _email("sess")
    token = _register(email)["token"]
    conn = sqlite3.connect(str(Path(os.environ["PP_DATA_DIR"]) / "auth.db"))
    hashes = [r[0] for r in conn.execute(
        "SELECT token_hash FROM sessions WHERE user_id = ?",
        (_user_id(email),)).fetchall()]
    conn.close()
    assert token not in hashes
    import hashlib
    assert hashlib.sha256(token.encode()).hexdigest() in hashes


def test_legacy_db_migration_keeps_data():
    """Legacy-БД (device_id NOT NULL, без orgs) мигрирует без потери данных."""
    legacy_dir = tempfile.mkdtemp(prefix="pp_auth_legacy_")
    db = Path(legacy_dir) / "auth.db"
    conn = sqlite3.connect(str(db))
    conn.executescript(
        """
        CREATE TABLE users (id TEXT PRIMARY KEY, email TEXT NOT NULL UNIQUE,
            password_hash TEXT NOT NULL, created_at REAL NOT NULL);
        CREATE TABLE sessions (token_hash TEXT PRIMARY KEY, user_id TEXT NOT NULL,
            device_id TEXT NOT NULL, created_at REAL NOT NULL,
            expires_at REAL NOT NULL);
        CREATE INDEX idx_sessions_user ON sessions(user_id);
        CREATE TABLE reset_codes (email TEXT NOT NULL, code_hash TEXT NOT NULL,
            created_at REAL NOT NULL, expires_at REAL NOT NULL,
            used INTEGER NOT NULL DEFAULT 0);
        """
    )
    import hashlib
    import secrets as _secrets
    salt = _secrets.token_hex(16)
    digest = hashlib.pbkdf2_hmac("sha256", b"secret1", bytes.fromhex(salt),
                                 200_000).hex()
    now = time.time()
    conn.execute("INSERT INTO users VALUES (?, ?, ?, ?)",
                 ("legacy-user", "legacy@example.com", f"{salt}${digest}", now))
    conn.execute("INSERT INTO sessions VALUES (?, ?, ?, ?, ?)",
                 ("a" * 64, "legacy-user", "old-device", now, now + 3600))
    conn.execute("INSERT INTO reset_codes VALUES (?, ?, ?, ?, 0)",
                 ("legacy@example.com", "b" * 64, now, now + 60))
    conn.commit()
    conn.close()

    env = dict(os.environ, PP_DATA_DIR=legacy_dir)
    import subprocess
    code = (
        "import os, sqlite3, time;"
        "from auth_app.main import _init_db, _orgs_of, _connect;"
        "_init_db();"
        "c = _connect();"
        "print(sorted(r['name'] for r in c.execute("
        "\"SELECT name FROM sqlite_master WHERE type='table'\") if not "
        "r['name'].startswith('sqlite_')));"
        "print(c.execute('SELECT COUNT(*) FROM sessions').fetchone()[0]);"
        "print(c.execute('SELECT device_id FROM sessions').fetchone()[0]);"
        "print(c.execute('SELECT COUNT(*) FROM users').fetchone()[0]);"
        "print(c.execute('SELECT user_id FROM reset_codes').fetchone()[0]);"
    )
    out = subprocess.run([sys.executable, "-c", code], cwd=str(ROOT),
                         env=env, capture_output=True, text=True)
    assert out.returncode == 0, out.stderr
    lines = out.stdout.strip().splitlines()
    tables = set(lines[0].strip("[]").replace("'", "").split(", "))
    assert {"users", "organizations", "memberships", "sessions",
            "reset_codes"} <= tables
    assert lines[1] == "1"                      # сессия сохранена
    assert lines[2] == "old-device"             # device_id сохранён
    assert lines[3] == "1"                      # пользователь сохранён
    assert lines[4] == "legacy-user"            # reset_codes связан с юзером
