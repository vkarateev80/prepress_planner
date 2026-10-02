# -*- coding: utf-8 -*-
"""Слой доступа к БД billing-сервиса: SQLite (PP_DATA_DIR) или PostgreSQL (DB_URL).

Основание: System Design v1 §13.2 (таблицы plans/orders/transactions/
subscriptions/entitlements) и ADR-3.

Особенности:
  * Единый SQL с плейсхолдерами `?`; для PostgreSQL они транслируются в `%s`.
  * Типы переносимы между SQLite и PostgreSQL: TEXT (идентификаторы, статусы,
    отметки времени в ISO-8601 UTC), INTEGER (деньги в рублях), BOOLEAN.
  * Таблицы identity (users/organizations/memberships) принадлежат auth
    (System Design §3.2) — billing хранит только org_id/user_id как ссылки и
    обеспечивает изоляцию тенантов фильтрацией по org_id (N-4).
  * Столбцы-алиасы (`amount`, `current_period_ends_at`, `created_at` в
    transactions) — вычисляемые (GENERATED ALWAYS AS … STORED): имена из
    task-spec без дублирования данных.
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
# Схема (System Design §13.2)
# --------------------------------------------------------------------------

SCHEMA: List[str] = [
    # plans — справочник тарифов (plan PK, features JSONB→TEXT).
    """
    CREATE TABLE IF NOT EXISTS plans (
        plan        TEXT PRIMARY KEY,
        title       TEXT NOT NULL,
        amount_rub  INTEGER NOT NULL DEFAULT 0,
        days        INTEGER NOT NULL DEFAULT 0,
        currency    TEXT NOT NULL DEFAULT 'RUB',
        features    TEXT NOT NULL DEFAULT '{}',
        updated_at  TEXT
    )
    """,
    # orders — заказы организации (provider_order_id — id платежа ЮKassa).
    """
    CREATE TABLE IF NOT EXISTS orders (
        id                TEXT PRIMARY KEY,
        org_id            TEXT NOT NULL,
        user_id           TEXT NOT NULL,
        plan              TEXT NOT NULL,
        amount_rub        INTEGER NOT NULL,
        currency          TEXT NOT NULL DEFAULT 'RUB',
        status            TEXT NOT NULL DEFAULT 'pending',
        provider_order_id TEXT,
        confirmation_url  TEXT,
        created_at        TEXT NOT NULL,
        paid_at           TEXT,
        refunded_at       TEXT
    )
    """,
    "CREATE INDEX IF NOT EXISTS idx_orders_org ON orders(org_id)",
    "CREATE INDEX IF NOT EXISTS idx_orders_provider ON orders(provider_order_id)",
    "CREATE INDEX IF NOT EXISTS idx_orders_status ON orders(status)",
    # transactions — журнал событий провайдера; идемпотентность по UNIQUE.
    """
    CREATE TABLE IF NOT EXISTS transactions (
        id                  TEXT PRIMARY KEY,
        order_id            TEXT,
        provider_payment_id TEXT UNIQUE,
        event_type          TEXT,
        amount_rub          INTEGER NOT NULL DEFAULT 0,
        amount              INTEGER GENERATED ALWAYS AS (amount_rub) STORED,
        currency            TEXT NOT NULL DEFAULT 'RUB',
        status              TEXT NOT NULL,
        raw_payload         TEXT,
        received_at         TEXT NOT NULL,
        created_at          TEXT GENERATED ALWAYS AS (received_at) STORED
    )
    """,
    "CREATE INDEX IF NOT EXISTS idx_tx_order ON transactions(order_id)",
    # subscriptions — подписка организации (одна на организацию).
    """
    CREATE TABLE IF NOT EXISTS subscriptions (
        id                       TEXT PRIMARY KEY,
        org_id                   TEXT NOT NULL UNIQUE,
        plan                     TEXT NOT NULL DEFAULT 'free',
        status                   TEXT NOT NULL DEFAULT 'trialing',
        trial_started_at         TEXT,
        trial_ends_at            TEXT,
        current_period_start     TEXT,
        current_period_end       TEXT,
        current_period_ends_at   TEXT GENERATED ALWAYS AS (current_period_end) STORED,
        cancel_at_period_end     BOOLEAN NOT NULL DEFAULT FALSE,
        provider_subscription_id TEXT,
        saved_payment_method_id  TEXT,
        renew_attempts           INTEGER NOT NULL DEFAULT 0,
        renew_last_attempt_at    TEXT,
        created_at               TEXT NOT NULL,
        updated_at               TEXT NOT NULL
    )
    """,
    "CREATE INDEX IF NOT EXISTS idx_subs_org ON subscriptions(org_id)",
    "CREATE INDEX IF NOT EXISTS idx_subs_status ON subscriptions(status)",
    # entitlements — проекция прав (источник истины: subscriptions + transactions).
    """
    CREATE TABLE IF NOT EXISTS entitlements (
        id         TEXT PRIMARY KEY,
        org_id     TEXT NOT NULL UNIQUE,
        plan       TEXT NOT NULL DEFAULT 'free',
        status     TEXT NOT NULL DEFAULT 'free',
        pro        BOOLEAN NOT NULL DEFAULT FALSE,
        features   TEXT NOT NULL DEFAULT '{}',
        "until"    TEXT,
        updated_at TEXT NOT NULL
    )
    """,
    "CREATE INDEX IF NOT EXISTS idx_ent_org ON entitlements(org_id)",
]

# Таблицы заглушки (services/payments до ADR-3) — переименовываются, не удаляются.
LEGACY_TABLES = ("orders", "subscriptions")


class Connection:
    """Обёртка над соединением: dict-строки, `?`-плейсхолдеры, commit/rollback."""

    def __init__(self, db: "Database", raw: Any) -> None:
        self.db = db
        self.raw = raw

    # -- низкий уровень ---------------------------------------------------
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

    def execute_script(self, statements: Iterable[str]) -> None:
        for stmt in statements:
            self.execute(stmt)

    def commit(self) -> None:
        self.raw.commit()

    def rollback(self) -> None:
        try:
            self.raw.rollback()
        except Exception:  # pragma: no cover - защита от повторного rollback
            pass

    def close(self) -> None:
        try:
            self.raw.close()
        except Exception:  # pragma: no cover
            pass

    # -- контекстный менеджер: commit при успехе, rollback при ошибке -----
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
                 sqlite_name: str = "payments.db") -> None:
        url = (db_url or "").strip()
        self.url = url
        self._lock = threading.RLock()
        self.kind = "sqlite"
        self.path: Optional[Path] = None
        self.dsn: Optional[str] = None

        if url.startswith("postgres://") or url.startswith("postgresql://"):
            self.kind = "postgresql"
            self.dsn = url
        elif url.startswith("sqlite:///"):
            self.kind = "sqlite"
            self.path = Path(url[len("sqlite:///"):])
        elif url.startswith("sqlite://"):
            # sqlite://<path> (относительный) и sqlite:///:memory:
            self.kind = "sqlite"
            tail = url[len("sqlite://"):].lstrip("/")
            self.path = Path("/" + tail) if url.startswith("sqlite:////") else Path(tail)
        elif url:
            scheme = url.split(":", 1)[0]
            raise DbError(
                f"DB_URL: неподдерживаемая схема {scheme!r}; "
                "ожидается postgresql://… или sqlite://…")
        else:
            base = Path(data_dir) if data_dir else Path(__file__).resolve().parent.parent / "data"
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
        """Транзакция под process-локом (идемпотентность webhook, продления)."""
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

    # -- трансляция SQL ---------------------------------------------------
    def _sql(self, sql: str) -> str:
        if self.kind == "postgresql":
            return sql.replace("?", "%s")
        return sql

    # -- служебное --------------------------------------------------------
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

    # -- схема ------------------------------------------------------------
    def _tables(self, conn: Connection) -> List[str]:
        if self.kind == "sqlite":
            rows = conn.query("SELECT name FROM sqlite_master WHERE type='table'")
        else:
            rows = conn.query(
                "SELECT table_name AS name FROM information_schema.tables "
                "WHERE table_schema='public'")
        return [r["name"] for r in rows]

    def _columns(self, conn: Connection, table: str) -> List[str]:
        if self.kind == "sqlite":
            rows = conn.query(f"PRAGMA table_info({table})")
            return [r["name"] for r in rows]
        rows = conn.query(
            "SELECT column_name AS name FROM information_schema.columns "
            "WHERE table_name = ? AND table_schema='public'", (table,))
        return [r["name"] for r in rows]

    def _migrate_legacy(self, conn: Connection) -> List[str]:
        """Заглушка (v0) → production-схема: старые таблицы переименовываются.

        Старая схема хранила подписку по user_id и не имела org_id/транзакций;
        это заглушка без реальных платежей, поэтому данные не переносятся —
        сохраняем их как `<table>_stub_v0` (не удаляем).
        """
        renamed: List[str] = []
        tables = self._tables(conn)
        for table in LEGACY_TABLES:
            if table not in tables:
                continue
            cols = self._columns(conn, table)
            if "org_id" in cols:
                continue  # уже новая схема
            target = f"{table}_stub_v0"
            if target in tables:
                continue
            conn.execute(f"ALTER TABLE {table} RENAME TO {target}")
            renamed.append(table)
        return renamed

    # Колонки, появившиеся после создания схемы (идемпотентная миграция).
    # `saved_payment_method_id` — сохранённый способ оплаты для автоплатежей;
    # ранее его писали в provider_subscription_id, значения переносятся.
    ENSURE_COLUMNS: List[tuple] = [
        ("subscriptions", "saved_payment_method_id", "TEXT", None),
        ("subscriptions", "renew_attempts", "INTEGER", "0"),
        ("subscriptions", "renew_last_attempt_at", "TEXT", None),
    ]

    def _ensure_columns(self, conn: Connection) -> List[str]:
        added: List[str] = []
        for table, column, decl, default in self.ENSURE_COLUMNS:
            if column in self._columns(conn, table):
                continue
            tail = f" DEFAULT {default}" if default is not None else ""
            conn.execute(f"ALTER TABLE {table} ADD COLUMN {column} {decl}{tail}")
            added.append(f"{table}.{column}")
        if "saved_payment_method_id" in added:
            # Перенос: раньше id сохранённого способа лежал в
            # provider_subscription_id (писал _extend_period).
            conn.execute(
                "UPDATE subscriptions SET saved_payment_method_id = "
                "provider_subscription_id "
                "WHERE saved_payment_method_id IS NULL "
                "AND provider_subscription_id IS NOT NULL")
        return added

    def init_schema(self) -> Dict[str, Any]:
        """Создать/актуализировать схему. Возвращает сведения для /healthz."""
        with self._lock:
            conn = self.connect()
            try:
                with conn:
                    renamed = self._migrate_legacy(conn)
                    conn.execute_script(SCHEMA)
                    self._ensure_columns(conn)
                return {"db": self.describe(), "renamed_legacy": renamed}
            finally:
                conn.close()


def is_unique_violation(exc: BaseException) -> bool:
    """Нарушение UNIQUE (идемпотентность webhook) — для SQLite и PostgreSQL."""
    name = type(exc).__name__
    if name in ("IntegrityError", "UniqueViolation"):
        text = str(exc).lower()
        return ("unique" in text or "duplicate" in text or name == "UniqueViolation")
    return False
