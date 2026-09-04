# -*- coding: utf-8 -*-
"""Тесты микросервиса авторизации."""
import os
import sys
import tempfile
from pathlib import Path

import pytest

# Изолированная БД + секрет до импорта приложения.
_tmp = tempfile.mkdtemp(prefix="pp_auth_test_")
os.environ["PP_DATA_DIR"] = _tmp
os.environ["PP_AUTH_SECRET"] = "test-secret-0123456789abcdef"
os.environ["PP_TOKEN_TTL"] = "1"

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from fastapi.testclient import TestClient  # noqa: E402

from auth_app.main import app  # noqa: E402
from auth_app.main import verify_token  # noqa: E402

client = TestClient(app)


def test_healthz():
    r = client.get("/healthz")
    assert r.status_code == 200
    assert r.json()["status"] == "ok"


def test_register_login_me():
    r = client.post("/auth/register",
                    json={"email": "User@Example.com", "password": "secret1"})
    assert r.status_code == 200, r.text
    data = r.json()
    assert data["token"]
    assert data["user"]["email"] == "user@example.com"
    token = data["token"]

    # me по токену
    r = client.get("/auth/me", headers={"Authorization": f"Bearer {token}"})
    assert r.status_code == 200
    assert r.json()["user"]["sub"]

    # повторная регистрация — 409
    r = client.post("/auth/register",
                    json={"email": "user@example.com", "password": "secret1"})
    assert r.status_code == 409

    # вход с верным паролем
    r = client.post("/auth/login",
                    json={"email": "user@example.com", "password": "secret1"})
    assert r.status_code == 200
    assert r.json()["token"]

    # вход с неверным паролем — 401
    r = client.post("/auth/login",
                    json={"email": "user@example.com", "password": "wrong!"})
    assert r.status_code == 401


def test_bad_email_and_short_password():
    r = client.post("/auth/register",
                    json={"email": "not-an-email", "password": "secret1"})
    assert r.status_code == 422
    r = client.post("/auth/register",
                    json={"email": "a@b.co", "password": "123"})
    assert r.status_code == 422


def test_me_without_token():
    r = client.get("/auth/me")
    assert r.status_code == 401


def test_verify_token_roundtrip():
    from auth_app.main import _sign_token
    with pytest.raises(Exception):
        verify_token("garbage-token")
    token = _sign_token("user-1", "u@example.com")
    claims = verify_token(token)
    assert claims["sub"] == "user-1"
    assert claims["email"] == "u@example.com"
