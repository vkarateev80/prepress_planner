# -*- coding: utf-8 -*-
"""Гигиена тестов `services/api` при реальном PostgreSQL.

SQLite в тестах — временный каталог на каждый запуск, а `PP_TEST_DB_URL`
ведёт на общую базу: без очистки строки накапливаются между тестами и
запусками (падает изоляция тенантов, лимиты, счётчики). Чистим все таблицы
`public` перед каждым тестом; схему создаёт штатный `build_runtime`.
"""
import os

import pytest


@pytest.fixture(autouse=True)
def _clean_pg_database():
    if not os.environ.get("PP_TEST_DB_URL"):
        yield
        return
    import psycopg2

    conn = psycopg2.connect(os.environ["PP_TEST_DB_URL"])
    conn.autocommit = True
    try:
        with conn.cursor() as cur:
            cur.execute(
                "SELECT tablename FROM pg_tables "
                "WHERE schemaname = 'public'")
            tables = [row[0] for row in cur.fetchall()]
            if tables:
                quoted = ", ".join('"%s"' % t for t in tables)
                cur.execute(f"TRUNCATE TABLE {quoted} RESTART IDENTITY CASCADE")
    finally:
        conn.close()
    yield
