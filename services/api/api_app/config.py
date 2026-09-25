# -*- coding: utf-8 -*-
"""Конфигурация сервиса `api` (control plane) — только env, секреты не в коде.

Основание: System Design v1 (ADR-5, ADR-6, ADR-7, §3.3/§3.4, §12.4-§12.8, §13.3)
и PRD v2 (F-1…F-4 — разбор/конвертация, N-4 — изоляция по аккаунту).

`api` — единственный владелец оркестрации и персистентности: пишет в PostgreSQL
(метаданные) и в S3-совместимое объектное хранилище (blobs ≤ 50 МБ), проверяет
сессию/членство через `auth POST /auth/verify`, вызывает конвертер
сервер-к-серверу (ADR-7) и — в следующих фазах — `domain-worker`.

env (см. services/api/.env.example):
  DB_URL                     — postgresql://… (System Design §13); пусто → SQLite
  PP_DATA_DIR                — каталог SQLite (PP_DATA_DIR/api.db)
  PP_AUTH_URL                — адрес auth (в docker http://auth:8121), обязателен
  PP_BILLING_URL             — адрес billing (в docker http://billing:8122)
  CONVERTER_URL              — адрес конвертера (в docker http://converter:8120)
  DOMAIN_WORKER_URL          — адрес domain-worker (следующая фаза, 8101)
  OBJECT_STORAGE_ENDPOINT    — S3-совместимый endpoint (в docker http://minio:9000)
  OBJECT_STORAGE_PUBLIC_ENDPOINT — внешний endpoint для presigned URL (через edge)
  OBJECT_STORAGE_BUCKET      — имя bucket (по умолчанию prepress-saas)
  OBJECT_STORAGE_REGION      — регион подписи (по умолчанию us-east-1)
  OBJECT_STORAGE_ACCESS_KEY / OBJECT_STORAGE_SECRET_KEY — ключи доступа
  OBJECT_STORAGE_PREFIX      — префикс ключей (по умолчанию org)
  PP_MAX_MB                  — лимит размера файла (50, F-2)
  PP_PRESIGN_TTL             — TTL presigned GET в секундах (300)
  PP_MAX_FILE_VERSIONS       — сколько версий хранится на файл (20)
  PP_AUTH_REQUIRED           — 1 (по умолчанию) — обязательный Bearer-токен
  PP_DEV_ORG_ID / PP_DEV_USER_ID — тестовый тенант при PP_AUTH_REQUIRED=0
  PP_ENTITLEMENT_ENFORCE     — 1 — спрашивать billing о лимите проектов (Free=1)
  PP_HTTP_TIMEOUT            — таймаут внутренних HTTP-вызовов (сек)
  PP_STORAGE_BACKEND         — s3 (по умолчанию) | memory (только тесты)
"""
from __future__ import annotations

import os
from typing import Any, Dict, Optional


def _env(source: Optional[Dict[str, str]], name: str, default: str = "") -> str:
    if source is not None and name in source:
        raw = source.get(name)
    else:
        raw = os.environ.get(name)
    return (raw or default).strip()


def _flag(value: str, default: bool = False) -> bool:
    v = (value or "").strip().lower()
    if not v:
        return default
    return v in ("1", "true", "yes", "on", "да")


def _num(value: str, default: float) -> float:
    v = (value or "").strip()
    if not v:
        return default
    try:
        return float(v)
    except ValueError:
        return default


class Config:
    """Настройки сервиса, собранные из env (или из явного словаря — тесты)."""

    def __init__(self, source: Optional[Dict[str, str]] = None) -> None:
        e = lambda name, default="": _env(source, name, default)  # noqa: E731

        self.db_url: str = e("DB_URL")
        self.data_dir: str = e("PP_DATA_DIR")

        self.auth_url: str = e("PP_AUTH_URL").rstrip("/")
        if not self.auth_url:
            raise RuntimeError(
                "PP_AUTH_URL обязателен (адрес микросервиса auth, в docker "
                "http://auth:8121)")

        self.billing_url: str = e("PP_BILLING_URL").rstrip("/")
        self.converter_url: str = e("CONVERTER_URL", "http://converter:8120").rstrip("/")
        self.domain_worker_url: str = e(
            "DOMAIN_WORKER_URL", "http://domain-worker:8101").rstrip("/")

        # --- гибридное хранилище (ADR-5) ---
        self.storage_endpoint: str = e(
            "OBJECT_STORAGE_ENDPOINT", "http://minio:9000").rstrip("/")
        self.storage_public_endpoint: str = (
            e("OBJECT_STORAGE_PUBLIC_ENDPOINT") or self.storage_endpoint).rstrip("/")
        self.storage_bucket: str = e("OBJECT_STORAGE_BUCKET", "prepress-saas")
        self.storage_region: str = e("OBJECT_STORAGE_REGION", "us-east-1")
        self.storage_access_key: str = e("OBJECT_STORAGE_ACCESS_KEY", "minioadmin")
        self.storage_secret_key: str = e("OBJECT_STORAGE_SECRET_KEY", "minioadmin")
        self.storage_prefix: str = e("OBJECT_STORAGE_PREFIX", "org").strip("/") or "org"
        self.storage_backend: str = e("PP_STORAGE_BACKEND", "s3").lower()
        self.presign_ttl: int = int(_num(e("PP_PRESIGN_TTL"), 300))

        # --- лимиты (F-2, N-4) ---
        self.max_mb: float = _num(e("PP_MAX_MB"), 50.0)
        self.max_file_versions: int = int(_num(e("PP_MAX_FILE_VERSIONS"), 20))
        # nginx допускает 64m (ADR-6); api отдаёт русскую ошибку вместо 413 nginx.
        self.max_upload_bytes: int = int(self.max_mb * 1024 * 1024)

        # --- авторизация/тенанты ---
        self.auth_required: bool = _flag(e("PP_AUTH_REQUIRED"), True)
        self.dev_org_id: str = e("PP_DEV_ORG_ID", "org-dev")
        self.dev_user_id: str = e("PP_DEV_USER_ID", "user-dev")
        self.dev_role: str = e("PP_DEV_ROLE", "owner")
        self.entitlement_enforce: bool = _flag(e("PP_ENTITLEMENT_ENFORCE"), True)

        self.http_timeout: float = _num(e("PP_HTTP_TIMEOUT"), 20.0)
        self.convert_timeout: float = _num(e("PP_CONVERT_TIMEOUT"), 220.0)
        self.convert_poll_interval: float = _num(e("PP_CONVERT_POLL_INTERVAL"), 1.0)

        # Допустимые mime/расширения (F-1, F-2, F-4).
        self.allowed_exts: tuple = (
            ".dxf", ".svg", ".pdf", ".ai", ".cdr", ".eps",
        )
        self.closed_exts: tuple = (".ai", ".cdr", ".eps")
        self.convert_target: str = e("PP_CONVERT_TARGET", "svg").lower()

        # Внешний верификатор токена (тесты подменяют фейком, см. auth.py).
        self.verifier: Optional[Any] = None

    # -- удобные свойства -------------------------------------------------
    @property
    def is_postgres(self) -> bool:
        return self.db_url.startswith(("postgres://", "postgresql://"))

    @property
    def sqlite_path(self) -> str:
        base = self.data_dir or os.path.join(
            os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "data")
        return os.path.join(base, "api.db")

    def describe(self) -> Dict[str, Any]:
        """Безопасное описание конфигурации для /healthz (без секретов)."""
        return {
            "auth_url": self.auth_url,
            "billing_url": self.billing_url,
            "converter_url": self.converter_url,
            "domain_worker_url": self.domain_worker_url,
            "storage_backend": self.storage_backend,
            "storage_bucket": self.storage_bucket,
            "storage_prefix": self.storage_prefix,
            "storage_endpoint": self.storage_endpoint,
            "auth_required": self.auth_required,
            "entitlement_enforce": self.entitlement_enforce,
            "max_mb": self.max_mb,
            "max_file_versions": self.max_file_versions,
            "presign_ttl": self.presign_ttl,
            "convert_target": self.convert_target,
        }
