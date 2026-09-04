# -*- coding: utf-8 -*-
"""Тесты микросервиса авторизации: сессии 1/1, forgot/reset, устройства."""
import os
import sys
import tempfile
from pathlib import Path

import pytest

# Изолированная БД до импорта приложения.
_tmp = tempfile.mkdtemp(prefix="pp_auth_test_")
os.environ["PP_DATA_DIR"] = _tmp
os.environ["PP_AUTH_SECRET"] = "test-secret-0123456789abcdef"
os.environ["PP_TOKEN_TTL"] = "1"
os.environ.pop("PP_SMTP_HOST", None)  # dev-режим: код в ответе

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from fastapi.testclient import TestClient  # noqa: E402

from auth_app.main import app  # noqa: E402
from auth_app.main import _session_claims  # noqa: E402

client = TestClient(app)


def _auth(token: str) -> dict:
    return {"Authorization": f"Bearer {token}"}


def test_healthz():
    r = client.get("/healthz")
    assert r.status_code == 200
    assert r.json()["sessions"] == "server-side"
    assert r.json()["device_limit"] == 1


def test_register_login_me():
    r = client.post("/auth/register", json={
        "email": "User@Example.com", "password": "secret1",
        "device_id": "dev-1"})
    assert r.status_code == 200, r.text
    data = r.json()
    assert data["token"]
    assert data["user"]["email"] == "user@example.com"
    token = data["token"]

    r = client.get("/auth/me", headers=_auth(token))
    assert r.status_code == 200
    assert r.json()["user"]["sub"]

    # Повторная регистрация — 409.
    r = client.post("/auth/register", json={
        "email": "user@example.com", "password": "secret1",
        "device_id": "dev-1"})
    assert r.status_code == 409

    # Вход с верным паролем; неверным — 401.
    r = client.post("/auth/login", json={
        "email": "user@example.com", "password": "secret1",
        "device_id": "dev-1"})
    assert r.status_code == 200
    r = client.post("/auth/login", json={
        "email": "user@example.com", "password": "wrong!",
        "device_id": "dev-1"})
    assert r.status_code == 401


def test_device_limit_1_1_evicts_old_session():
    """Политика 1/1: вход со второго устройства отзывает первую сессию."""
    r = client.post("/auth/register", json={
        "email": "two@example.com", "password": "secret1",
        "device_id": "dev-a"})
    assert r.status_code == 200
    token_a = r.json()["token"]

    # Сессии на первом устройстве — одна, current.
    r = client.get("/auth/devices", headers=_auth(token_a))
    assert r.status_code == 200
    devs = r.json()["devices"]
    assert len(devs) == 1 and devs[0]["current"] is True

    # Вход с dev-b: старая сессия отозвана.
    r = client.post("/auth/login", json={
        "email": "two@example.com", "password": "secret1",
        "device_id": "dev-b"})
    assert r.status_code == 200
    token_b = r.json()["token"]

    r = client.get("/auth/devices", headers=_auth(token_b))
    devs = r.json()["devices"]
    assert len(devs) == 1
    assert devs[0]["device_id"] == "dev-b"

    # Старый токен больше не действует.
    r = client.get("/auth/me", headers=_auth(token_a))
    assert r.status_code == 401


def test_logout_revokes_session():
    r = client.post("/auth/register", json={
        "email": "bye@example.com", "password": "secret1",
        "device_id": "dev-1"})
    token = r.json()["token"]
    r = client.post("/auth/logout", headers=_auth(token))
    assert r.status_code == 200
    r = client.get("/auth/me", headers=_auth(token))
    assert r.status_code == 401


def test_forgot_reset_flow():
    r = client.post("/auth/register", json={
        "email": "reset@example.com", "password": "old-pass1",
        "device_id": "dev-1"})
    assert r.status_code == 200
    old_token = r.json()["token"]

    # Forgot: dev-режим без SMTP возвращает код.
    r = client.post("/auth/forgot", json={"email": "reset@example.com"})
    assert r.status_code == 200
    code = r.json().get("dev_code")
    assert code and len(code) == 6

    # Reset: неверный код — 400.
    r = client.post("/auth/reset", json={
        "email": "reset@example.com", "code": "000000",
        "new_password": "new-pass1"})
    assert r.status_code == 400

    # Reset: верный код — пароль сменён, сессии отозваны.
    r = client.post("/auth/reset", json={
        "email": "reset@example.com", "code": code,
        "new_password": "new-pass1"})
    assert r.status_code == 200, r.text

    r = client.get("/auth/me", headers=_auth(old_token))
    assert r.status_code == 401  # сессии отозваны

    # Старый пароль не подходит, новый — да.
    r = client.post("/auth/login", json={
        "email": "reset@example.com", "password": "old-pass1",
        "device_id": "dev-1"})
    assert r.status_code == 401
    r = client.post("/auth/login", json={
        "email": "reset@example.com", "password": "new-pass1",
        "device_id": "dev-1"})
    assert r.status_code == 200

    # Код одноразовый: повторный reset с тем же кодом — 400.
    r = client.post("/auth/reset", json={
        "email": "reset@example.com", "code": code,
        "new_password": "new-pass2"})
    assert r.status_code == 400


def test_forgot_for_unknown_email_dev_hint():
    r = client.post("/auth/forgot", json={"email": "ghost@example.com"})
    assert r.status_code == 200
    assert "dev_hint" in r.json()


def test_bad_email_and_short_password():
    r = client.post("/auth/register", json={
        "email": "not-an-email", "password": "secret1", "device_id": "d1"})
    assert r.status_code == 422
    r = client.post("/auth/register", json={
        "email": "a@b.co", "password": "123", "device_id": "d1"})
    assert r.status_code == 422


def test_me_without_token():
    r = client.get("/auth/me")
    assert r.status_code == 401


def test_verify_endpoint():
    r = client.post("/auth/register", json={
        "email": "ver@example.com", "password": "secret1",
        "device_id": "dev-1"})
    token = r.json()["token"]
    r = client.post("/auth/verify", headers=_auth(token))
    assert r.status_code == 200
    body = r.json()
    assert body["sub"] and body["email"] == "ver@example.com"

    r = client.post("/auth/verify", headers=_auth("bogus"))
    assert r.status_code == 401
