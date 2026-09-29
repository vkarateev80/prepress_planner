# -*- coding: utf-8 -*-
"""Лёгкий слой БД для админ-панели.

`DB_URL` — как во всём контуре: `postgresql://…` в проде (psycopg2) либо
путь к SQLite (тесты). Плейсхолдеры — только `?`; для PostgreSQL они
транслируются в `%s`. Запросы админки — короткие read/однотранзакционные
write (grant/revoke подписки), блокировки SQLite обсуждаемы с auth.
"""
from __future__ import annotations

import sqlite3
import threading
from typing import Any, Dict, List, Optional, Sequence


class AdminDbError(RuntimeError):
    """Ошибка конфигурации/доступа к БД (сообщения — русские)."""


def _translate(sql: str, pg: bool) -> str:
    return sql.replace("?", "%s") if pg else sql


def _jsonable(value: Any) -> Any:
    if isinstance(value, (str, int, float, bool)) or value is None:
        return value
    return str(value)


class AdminDb:
    """Минимальный коннектор: query/exec/tx, dict-строки, `?`-плейсхолдеры."""

    def __init__(self, db_url: str) -> None:
        self.db_url = (db_url or "").strip()
        self._pg = self.db_url.startswith("postgres")
        self._lock = threading.RLock()
        if not self._pg and not self.db_url:
            raise AdminDbError("DB_URL не задан")

    def _connect(self):  # -> sqlite3.Connection | psycopg2 connection
        if self._pg:
            try:
                import psycopg2  # type: ignore
            except ImportError as exc:  # pragma: no cover
                raise AdminDbError(
                    "DB_URL указывает на PostgreSQL, но psycopg2 не установлен"
                ) from exc
            return psycopg2.connect(self.db_url)
        conn = sqlite3.connect(self.db_url, check_same_thread=False,
                               timeout=10)
        conn.row_factory = sqlite3.Row
        return conn

    def query(self, sql: str,
              params: Sequence[Any] = ()) -> List[Dict[str, Any]]:
        with self._lock:
            conn = self._connect()
            try:
                cur = conn.cursor()
                cur.execute(_translate(sql, self._pg), tuple(params))
                if cur.description is None:
                    rows: List[Dict[str, Any]] = []
                elif self._pg:
                    names = [d[0] for d in cur.description]
                    rows = [dict(zip(names, r)) for r in cur.fetchall()]
                else:
                    rows = [dict(r) for r in cur.fetchall()]
                return [{k: _jsonable(v) for k, v in row.items()}
                        for row in rows]
            finally:
                conn.close()

    def exec(self, sql: str, params: Sequence[Any] = ()) -> int:
        with self._lock:
            conn = self._connect()
            try:
                cur = conn.cursor()
                cur.execute(_translate(sql, self._pg), tuple(params))
                affected = cur.rowcount if cur.description is None else 0
                conn.commit()
                return int(affected or 0)
            finally:
                conn.close()

    def tx(self):
        """Контекст: одна транзакция, commit/rollback (для grant/revoke)."""
        return _Tx(self)


class _Tx:
    def __init__(self, db: AdminDb) -> None:
        self.db = db

    def __enter__(self):
        self.conn = self.db._connect()
        self.cur = self.conn.cursor()
        return self

    def __exit__(self, exc_type, exc, tb) -> None:
        try:
            if exc_type is None:
                self.conn.commit()
            else:
                self.conn.rollback()
        finally:
            self.conn.close()

    def query(self, sql: str, params: Sequence[Any] = ()) -> List[Dict[Any, Any]]:
        self.cur.execute(_translate(sql, self.db._pg), tuple(params))
        if self.cur.description is None:
            return []
        if self.db._pg:
            names = [d[0] for d in self.cur.description]
            rows = [dict(zip(names, r)) for r in self.cur.fetchall()]
        else:
            rows = [dict(r) for r in self.cur.fetchall()]
        return [{k: _jsonable(v) for k, v in row.items()} for row in rows]

    def exec(self, sql: str, params: Sequence[Any] = ()) -> int:
        self.cur.execute(_translate(sql, self.db._pg), tuple(params))
        return int(self.cur.rowcount or 0)
