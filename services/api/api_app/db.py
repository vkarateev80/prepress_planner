# -*- coding: utf-8 -*-
"""Слой доступа к БД сервиса `api`: SQLite (PP_DATA_DIR) или PostgreSQL (DB_URL).

Основание: System Design v1 §13.3 (таблицы `projects`, `files`,
`file_versions`, `reports`) и ADR-5 (гибрид: blobs — в S3, метаданные — в БД).

Особенности (повторяют проверенный паттерн `services/payments/payments_app/db.py`):
  * один SQL с плейсхолдерами `?`, для PostgreSQL они транслируются в `%s`;
  * переносимые типы: TEXT (идентификаторы, статусы, ISO-8601 UTC), BIGINT,
    BOOLEAN, JSON/TEXT; в PostgreSQL дублируются `timestamptz`-алиасы,
    в SQLite — GENERATED-алиасы имён из task-spec (`type`, `original_name`);
  * **изоляция тенантов (N-4)**: `org_id` есть в каждой строке, а все выборки
    выполняются с фильтром `org_id = ?` — row-level изоляция на уровне SQL;
  * soft delete: `deleted_at` у `projects`/`files`/`file_versions`/`reports`;
  * таблицы identity (users/organizations) принадлежат `auth` — здесь только
    ссылки `org_id`/`created_by` (System Design §3.2).
"""
from __future__ import annotations

import sqlite3
import threading
from contextlib import contextmanager
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional, Sequence
from urllib.parse import urlsplit, urlunsplit


class DbError(RuntimeError):
    """Ошибка конфигурации/доступа к БД (сообщения — русские)."""


# --------------------------------------------------------------------------
# Схема (System Design §13.3)
# --------------------------------------------------------------------------

def _schema(postgres: bool) -> List[str]:
    """DDL. Различия СУБД минимальны и локализованы здесь."""
    if postgres:
        ts_cols = lambda name, col: (  # noqa: E731
            f'"{name}" TIMESTAMPTZ')
        blob = "JSONB"
        bigint = "BIGINT"
        bool_t = "BOOLEAN"
    else:
        ts_cols = None
        blob = "TEXT"
        bigint = "INTEGER"
        bool_t = "INTEGER"

    stmts: List[str] = []

    # projects — проект организации; state_json — текущее состояние
    # (схема project_state.json v2, App: app/lib/src/projects/project.dart).
    if postgres:
        stmts.append("""
        CREATE TABLE IF NOT EXISTS projects (
            id              TEXT PRIMARY KEY,
            org_id          TEXT NOT NULL,
            name            TEXT NOT NULL,
            created_by      TEXT,
            created_at      TEXT NOT NULL,
            created_at_ts   TIMESTAMPTZ,
            updated_at      TEXT NOT NULL,
            updated_at_ts   TIMESTAMPTZ,
            deleted_at      TEXT,
            state_json      JSONB NOT NULL DEFAULT '{}'::jsonb,
            state_json_blob JSONB GENERATED ALWAYS AS (state_json) STORED
        )
        """)
    else:
        stmts.append("""
        CREATE TABLE IF NOT EXISTS projects (
            id              TEXT PRIMARY KEY,
            org_id          TEXT NOT NULL,
            name            TEXT NOT NULL,
            created_by      TEXT,
            created_at      TEXT NOT NULL,
            updated_at      TEXT NOT NULL,
            deleted_at      TEXT,
            state_json      TEXT NOT NULL DEFAULT '{}',
            state_json_blob TEXT GENERATED ALWAYS AS (state_json) VIRTUAL
        )
        """)
    stmts += [
        "CREATE INDEX IF NOT EXISTS idx_projects_org ON projects(org_id)",
        "CREATE INDEX IF NOT EXISTS idx_projects_org_name ON projects(org_id, name)",
    ]

    # files — логический файл проекта. `file_type` — из task-spec
    # (original/converter_result/healed_master/array/result/report);
    # `source_kind` — имя из System Design §13.3 (uploaded/converted/generated).
    if postgres:
        stmts.append(f"""
        CREATE TABLE IF NOT EXISTS files (
            id              TEXT PRIMARY KEY,
            org_id          TEXT NOT NULL,
            project_id      TEXT NOT NULL,
            name            TEXT NOT NULL,
            original_name   TEXT GENERATED ALWAYS AS (name) STORED,
            file_type       TEXT NOT NULL DEFAULT 'original',
            source_kind     TEXT NOT NULL DEFAULT 'uploaded',
            mime            TEXT,
            size_bytes      {bigint} NOT NULL DEFAULT 0,
            checksum_sha256 TEXT,
            storage_key     TEXT,
            version         INTEGER NOT NULL DEFAULT 1,
            parent_file_id  TEXT,
            created_by      TEXT,
            created_at      TEXT NOT NULL,
            created_at_ts   TIMESTAMPTZ,
            updated_at      TEXT NOT NULL,
            updated_at_ts   TIMESTAMPTZ,
            deleted_at      TEXT
        )
        """)
    else:
        stmts.append("""
        CREATE TABLE IF NOT EXISTS files (
            id              TEXT PRIMARY KEY,
            org_id          TEXT NOT NULL,
            project_id      TEXT NOT NULL,
            name            TEXT NOT NULL,
            original_name   TEXT,
            file_type       TEXT NOT NULL DEFAULT 'original',
            source_kind     TEXT NOT NULL DEFAULT 'uploaded',
            mime            TEXT,
            size_bytes      INTEGER NOT NULL DEFAULT 0,
            checksum_sha256 TEXT,
            storage_key     TEXT,
            version         INTEGER NOT NULL DEFAULT 1,
            parent_file_id  TEXT,
            created_by      TEXT,
            created_at      TEXT NOT NULL,
            updated_at      TEXT NOT NULL,
            deleted_at      TEXT
        )
        """)
    stmts += [
        "CREATE INDEX IF NOT EXISTS idx_files_org ON files(org_id)",
        "CREATE INDEX IF NOT EXISTS idx_files_project ON files(org_id, project_id)",
        "CREATE INDEX IF NOT EXISTS idx_files_parent ON files(parent_file_id)",
    ]

    # file_versions — история версий файла: каждый blob в object storage
    # со своим ключом и sha256 (UNIQUE(file_id, version)).
    if postgres:
        stmts.append(f"""
        CREATE TABLE IF NOT EXISTS file_versions (
            id              TEXT PRIMARY KEY,
            file_id         TEXT NOT NULL,
            org_id          TEXT NOT NULL,
            version         INTEGER NOT NULL,
            storage_key     TEXT NOT NULL,
            checksum_sha256 TEXT NOT NULL,
            size_bytes      {bigint} NOT NULL DEFAULT 0,
            mime            TEXT,
            kind            TEXT NOT NULL DEFAULT 'original',
            geometry        JSONB,
            created_by      TEXT,
            created_at      TEXT NOT NULL,
            created_at_ts   TIMESTAMPTZ,
            updated_at      TEXT NOT NULL,
            updated_at_ts   TIMESTAMPTZ,
            deleted_at      TEXT,
            UNIQUE (file_id, version)
        )
        """)
    else:
        stmts.append(f"""
        CREATE TABLE IF NOT EXISTS file_versions (
            id              TEXT PRIMARY KEY,
            file_id         TEXT NOT NULL,
            org_id          TEXT NOT NULL,
            version         INTEGER NOT NULL,
            storage_key     TEXT NOT NULL,
            checksum_sha256 TEXT NOT NULL,
            size_bytes      {bigint} NOT NULL DEFAULT 0,
            mime            TEXT,
            kind            TEXT NOT NULL DEFAULT 'original',
            geometry        TEXT,
            created_by      TEXT,
            created_at      TEXT NOT NULL,
            updated_at      TEXT NOT NULL,
            deleted_at      TEXT,
            UNIQUE (file_id, version)
        )
        """)
    stmts += [
        "CREATE INDEX IF NOT EXISTS idx_versions_file ON file_versions(org_id, file_id)",
        "CREATE INDEX IF NOT EXISTS idx_versions_storage ON file_versions(storage_key)",
    ]

    # reports — сгенерированные документы (PDF/XLSX/DXF), тоже объекты (ADR-5).
    if postgres:
        stmts.append(f"""
        CREATE TABLE IF NOT EXISTS reports (
            id          TEXT PRIMARY KEY,
            org_id      TEXT NOT NULL,
            project_id  TEXT NOT NULL,
            file_id     TEXT,
            kind        TEXT NOT NULL,
            report_type TEXT GENERATED ALWAYS AS (kind) STORED,
            storage_key TEXT NOT NULL,
            checksum_sha256 TEXT,
            size_bytes  {bigint} NOT NULL DEFAULT 0,
            created_by  TEXT,
            generated_at TEXT NOT NULL,
            created_at_ts TIMESTAMPTZ,
            created_at  TEXT NOT NULL,
            updated_at  TEXT NOT NULL,
            deleted_at  TEXT,
            CONSTRAINT reports_kind_chk CHECK (kind IN ('pdf', 'xlsx', 'dxf'))
        )
        """)
    else:
        stmts.append(f"""
        CREATE TABLE IF NOT EXISTS reports (
            id          TEXT PRIMARY KEY,
            org_id      TEXT NOT NULL,
            project_id  TEXT NOT NULL,
            file_id     TEXT,
            kind        TEXT NOT NULL,
            report_type TEXT GENERATED ALWAYS AS (kind) VIRTUAL,
            storage_key TEXT NOT NULL,
            checksum_sha256 TEXT,
            size_bytes  {bigint} NOT NULL DEFAULT 0,
            created_by  TEXT,
            generated_at TEXT NOT NULL,
            created_at  TEXT NOT NULL,
            updated_at  TEXT NOT NULL,
            deleted_at  TEXT,
            CONSTRAINT reports_kind_chk CHECK (kind IN ('pdf', 'xlsx', 'dxf'))
        )
        """)
    stmts += [
        "CREATE INDEX IF NOT EXISTS idx_reports_org ON reports(org_id)",
        "CREATE INDEX IF NOT EXISTS idx_reports_project ON reports(org_id, project_id)",
    ]

    return stmts


SCHEMA = _schema(False)
SCHEMA_POSTGRES = _schema(True)


class Connection:
    """Обёртка над соединением: dict-строки, `?`-плейсхолдеры, commit/rollback."""

    def __init__(self, db: "Database", raw: Any) -> None:
        self.db = db
        self.raw = raw

    def _cursor(self):
        return self.raw.cursor()

    def query(self, sql: str, params: Sequence[Any] = ()) -> List[Dict[str, Any]]:
        cur = self._cursor()
        try:
            cur.execute(self.db._sql(sql), tuple(params))
            return [dict(r) for r in cur.fetchall()]
        finally:
            cur.close()

    def query_one(self, sql: str, params: Sequence[Any] = ()) -> Optional[Dict[str, Any]]:
        rows = self.query(sql, params)
        return rows[0] if rows else None

    def execute(self, sql: str, params: Sequence[Any] = ()) -> int:
        cur = self._cursor()
        try:
            cur.execute(self.db._sql(sql), tuple(params))
            return cur.rowcount
        finally:
            cur.close()

    def insert(self, sql: str, params: Sequence[Any] = ()) -> None:
        self.execute(sql, params)

    def commit(self) -> None:
        self.raw.commit()

    def rollback(self) -> None:
        try:
            self.raw.rollback()
        except Exception:  # pragma: no cover
            pass

    def close(self) -> None:
        try:
            self.raw.close()
        except Exception:  # pragma: no cover
            pass

    def __enter__(self) -> "Connection":
        return self

    def __exit__(self, exc_type, exc, tb) -> bool:
        if exc_type is None:
            self.commit()
        else:
            self.rollback()
        self.close()
        return False


class Database:
    """Подключение к SQLite или PostgreSQL, выбранное по DB_URL."""

    def __init__(self, db_url: str = "", data_dir: str = "",
                 sqlite_name: str = "api.db") -> None:
        url = (db_url or "").strip()
        self.url = url
        self._lock = threading.RLock()
        self.kind = "sqlite"
        self.path: Optional[Path] = None
        self.dsn: Optional[str] = None

        if url.startswith(("postgres://", "postgresql://")):
            self.kind = "postgresql"
            self.dsn = url
        elif url.startswith("sqlite:///"):
            self.kind = "sqlite"
            self.path = Path(url[len("sqlite:///"):])
        elif url.startswith("sqlite://"):
            tail = url[len("sqlite://"):].lstrip("/")
            self.kind = "sqlite"
            self.path = Path("/" + tail) if url.startswith("sqlite:////") else Path(tail)
        elif url:
            scheme = url.split(":", 1)[0]
            raise DbError(
                f"DB_URL: неподдерживаемая схема {scheme!r}; "
                "ожидается postgresql://… или sqlite://…")
        else:
            base = Path(data_dir) if data_dir else (
                Path(__file__).resolve().parent.parent / "data")
            self.path = base / sqlite_name

        if self.kind == "sqlite" and self.path is not None:
            if str(self.path) != ":memory:":
                self.path.parent.mkdir(parents=True, exist_ok=True)

    # -- подключение ------------------------------------------------------
    def connect(self) -> Connection:
        if self.kind == "sqlite":
            raw = sqlite3.connect(str(self.path), check_same_thread=False, timeout=15)
            raw.row_factory = sqlite3.Row
            raw.execute("PRAGMA foreign_keys=ON")
            if str(self.path) != ":memory:":
                raw.execute("PRAGMA journal_mode=WAL")
            return Connection(self, raw)
        try:
            import psycopg2  # noqa: WPS433 (импорт по требованию)
            from psycopg2.extras import RealDictCursor
        except ImportError as exc:  # pragma: no cover - зависит от окружения
            raise DbError(
                "DB_URL указывает на PostgreSQL, но пакет psycopg2 не установлен "
                "(pip install psycopg2-binary)") from exc
        raw = psycopg2.connect(self.dsn, cursor_factory=RealDictCursor)
        return Connection(self, raw)

    @contextmanager
    def tx(self):
        """Транзакция под process-локом (создание проекта + запись файла)."""
        with self._lock:
            conn = self.connect()
            try:
                with conn:
                    yield conn
            finally:
                conn.close()

    @contextmanager
    def read(self):
        with self._lock:
            conn = self.connect()
            try:
                yield conn
            finally:
                conn.close()

    # -- транslate SQL ----------------------------------------------------
    def _sql(self, sql: str) -> str:
        if self.kind == "postgresql":
            return sql.replace("?", "%s")
        return sql

    def init_schema(self) -> List[str]:
        """Создать/дополнить схему (идемпотентно). Возвращает список статей."""
        stmts = SCHEMA_POSTGRES if self.kind == "postgresql" else SCHEMA
        applied: List[str] = []
        with self.tx() as conn:
            for stmt in stmts:
                try:
                    conn.execute(stmt)
                    applied.append("ok")
                except Exception as exc:  # noqa: BLE001
                    msg = str(exc).lower()
                    # Повторный ALTER/индекс — не ошибка миграции.
                    if "already exists" in msg or "duplicate" in msg:
                        applied.append("skip")
                        continue
                    raise DbError(f"Ошибка миграции схемы: {exc}") from exc
        return applied

    def describe(self) -> str:
        """Безопасное описание цели БД для /healthz (без пароля)."""
        if self.kind == "sqlite":
            return f"sqlite:{self.path}"
        parts = urlsplit(self.dsn or "")
        netloc = parts.netloc
        if "@" in netloc:
            user = netloc.split("@", 1)[0].split(":", 1)[0]
            netloc = f"{user}:***@{netloc.split('@', 1)[1]}"
        return urlunsplit((parts.scheme, netloc, parts.path, "", ""))

    def tables(self) -> List[str]:
        with self.read() as conn:
            if self.kind == "sqlite":
                rows = conn.query(
                    "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name")
            else:
                rows = conn.query(
                    "SELECT table_name AS name FROM information_schema.tables "
                    "WHERE table_schema='public' ORDER BY table_name")
        return [r["name"] for r in rows]

    def close(self) -> None:  # совместимость с жизненным циклом приложения
        return None


def rows_to_dicts(rows: Iterable[Any]) -> List[Dict[str, Any]]:
    out: List[Dict[str, Any]] = []
    for r in rows:
        out.append(dict(r) if not isinstance(r, dict) else r)
    return out
