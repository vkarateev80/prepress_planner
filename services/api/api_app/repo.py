# -*- coding: utf-8 -*-
"""Репозиторий `api`: проекты, файлы, версии, отчёты (System Design §13.3).

Каждая функция принимает `org_id` и **всегда** фильтрует по нему (N-4):
row-level изоляция обеспечивается SQL-условием `org_id = ?`, а не проверкой в
памяти. Blob пишется в объектное хранилище по ключу
`org/{org_id}/project/{project_id}/file/{file_id}/{version}/{sha256}/{name}`
(двойной рубеж изоляции из ADR-5).
"""
from __future__ import annotations

import json
import uuid
from typing import Any, Dict, List, Optional

from .db import Database
from .storage import ObjectStorage, StorageError, build_storage_key, sha256_hex

# Типы файлов (task-spec) и их соответствие §13.3 (`source_kind`).
FILE_TYPES = (
    "original", "converter_result", "healed_master", "array", "result", "report",
)
VERSION_KINDS = ("original", "converted", "healed", "master", "array", "report")

_SOURCE_KIND_BY_FILE_TYPE = {
    "original": "uploaded",
    "converter_result": "converted",
    "healed_master": "generated",
    "array": "generated",
    "result": "generated",
    "report": "generated",
}
_KIND_BY_FILE_TYPE = {
    "original": "original",
    "converter_result": "converted",
    "healed_master": "healed",
    "array": "array",
    "result": "master",
    "report": "report",
}


def now_iso() -> str:
    from datetime import datetime, timezone
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat()


def new_id(prefix: str = "") -> str:
    raw = uuid.uuid4().hex
    return f"{prefix}{raw}" if prefix else raw


def _json_state(value: Any) -> str:
    if value is None:
        return "{}"
    if isinstance(value, str):
        return value or "{}"
    return json.dumps(value, ensure_ascii=False)


def parse_state(value: Any) -> Dict[str, Any]:
    if not value:
        return {}
    if isinstance(value, dict):
        return value
    try:
        out = json.loads(value)
        return out if isinstance(out, dict) else {}
    except (TypeError, ValueError):
        return {}


# --------------------------------------------------------------------------
# Сериализация (JSON-контракт §12.4/§12.5 + task-spec)
# --------------------------------------------------------------------------

def project_json(row: Dict[str, Any], *, files: Optional[List[Dict[str, Any]]] = None,
                 versions: Optional[List[Dict[str, Any]]] = None) -> Dict[str, Any]:
    out: Dict[str, Any] = {
        "id": row["id"],
        "org_id": row["org_id"],
        "name": row["name"],
        "created_by": row.get("created_by"),
        "created_at": row.get("created_at"),
        "updated_at": row.get("updated_at"),
        "deleted_at": row.get("deleted_at"),
        "state": parse_state(row.get("state_json")),
    }
    if files is not None:
        out["files"] = files
    if versions is not None:
        out["versions"] = versions
    return out


def file_json(row: Dict[str, Any]) -> Dict[str, Any]:
    return {
        "id": row["id"],
        "org_id": row["org_id"],
        "project_id": row["project_id"],
        "name": row.get("name"),
        "original_name": row.get("original_name") or row.get("name"),
        "file_type": row.get("file_type"),
        "source_kind": row.get("source_kind"),
        "mime": row.get("mime"),
        "size_bytes": int(row.get("size_bytes") or 0),
        "checksum_sha256": row.get("checksum_sha256"),
        "storage_key": row.get("storage_key"),
        "version": int(row.get("version") or 1),
        "parent_file_id": row.get("parent_file_id"),
        "created_by": row.get("created_by"),
        "created_at": row.get("created_at"),
        "updated_at": row.get("updated_at"),
        "deleted_at": row.get("deleted_at"),
    }


def version_json(row: Dict[str, Any]) -> Dict[str, Any]:
    return {
        "id": row["id"],
        "file_id": row["file_id"],
        "org_id": row["org_id"],
        "version": int(row.get("version") or 1),
        "kind": row.get("kind"),
        "storage_key": row.get("storage_key"),
        "checksum_sha256": row.get("checksum_sha256"),
        "size_bytes": int(row.get("size_bytes") or 0),
        "mime": row.get("mime"),
        "geometry": parse_state(row.get("geometry")) or None,
        "created_at": row.get("created_at"),
        "updated_at": row.get("updated_at"),
        "deleted_at": row.get("deleted_at"),
    }


def report_json(row: Dict[str, Any]) -> Dict[str, Any]:
    return {
        "id": row["id"],
        "org_id": row["org_id"],
        "project_id": row["project_id"],
        "file_id": row.get("file_id"),
        "kind": row.get("kind"),
        "type": row.get("report_type") or row.get("kind"),
        "storage_key": row.get("storage_key"),
        "checksum_sha256": row.get("checksum_sha256"),
        "size_bytes": int(row.get("size_bytes") or 0),
        "generated_at": row.get("generated_at"),
        "created_at": row.get("created_at"),
        "deleted_at": row.get("deleted_at"),
    }


# --------------------------------------------------------------------------
# Репозиторий
# --------------------------------------------------------------------------

class Repo:
    """Единая точка доступа к БД + объектному хранилищу для сервиса `api`."""

    def __init__(self, db: Database, storage: Optional[ObjectStorage] = None,
                 key_prefix: str = "org", max_versions: int = 20) -> None:
        self.db = db
        self.storage = storage
        self.key_prefix = (key_prefix or "org").strip("/") or "org"
        self.max_versions = max(1, int(max_versions or 20))

    # -- projects ---------------------------------------------------------
    def create_project(self, org_id: str, name: str, created_by: str,
                       state: Optional[Any] = None) -> Dict[str, Any]:
        pid = new_id("prj_")
        ts = now_iso()
        with self.db.tx() as conn:
            conn.execute(
                "INSERT INTO projects (id, org_id, name, created_by, created_at,"
                " updated_at, deleted_at, state_json) VALUES (?,?,?,?,?,?,NULL,?)",
                (pid, org_id, name, created_by, ts, ts, _json_state(state)))
        row = self.get_project(org_id, pid)
        assert row is not None  # только что создан
        return row

    def get_project(self, org_id: str, project_id: str,
                    include_deleted: bool = False) -> Optional[Dict[str, Any]]:
        sql = "SELECT * FROM projects WHERE id = ? AND org_id = ?"
        if not include_deleted:
            sql += " AND deleted_at IS NULL"
        with self.db.read() as conn:
            return conn.query_one(sql, (project_id, org_id))

    def list_projects(self, org_id: str, limit: int = 200,
                      offset: int = 0) -> List[Dict[str, Any]]:
        with self.db.read() as conn:
            return conn.query(
                "SELECT * FROM projects WHERE org_id = ? AND deleted_at IS NULL"
                " ORDER BY created_at DESC, id LIMIT ? OFFSET ?",
                (org_id, int(limit), int(offset)))

    def count_projects(self, org_id: str) -> int:
        with self.db.read() as conn:
            row = conn.query_one(
                "SELECT COUNT(*) AS n FROM projects"
                " WHERE org_id = ? AND deleted_at IS NULL", (org_id,))
        return int((row or {}).get("n") or 0)

    def rename_project(self, org_id: str, project_id: str, name: str) -> bool:
        with self.db.tx() as conn:
            n = conn.execute(
                "UPDATE projects SET name = ?, updated_at = ?"
                " WHERE id = ? AND org_id = ? AND deleted_at IS NULL",
                (name, now_iso(), project_id, org_id))
        return n > 0

    def put_project_state(self, org_id: str, project_id: str,
                          state: Any) -> bool:
        with self.db.tx() as conn:
            n = conn.execute(
                "UPDATE projects SET state_json = ?, updated_at = ?"
                " WHERE id = ? AND org_id = ? AND deleted_at IS NULL",
                (_json_state(state), now_iso(), project_id, org_id))
        return n > 0

    def delete_project(self, org_id: str, project_id: str) -> bool:
        """Мягкое удаление проекта и всех его файлов (blobs не трогаем)."""
        ts = now_iso()
        with self.db.tx() as conn:
            n = conn.execute(
                "UPDATE projects SET deleted_at = ?, updated_at = ?"
                " WHERE id = ? AND org_id = ? AND deleted_at IS NULL",
                (ts, ts, project_id, org_id))
            if n:
                conn.execute(
                    "UPDATE files SET deleted_at = ?, updated_at = ?"
                    " WHERE project_id = ? AND org_id = ? AND deleted_at IS NULL",
                    (ts, ts, project_id, org_id))
                conn.execute(
                    "UPDATE file_versions SET deleted_at = ?, updated_at = ?"
                    " WHERE file_id IN (SELECT id FROM files WHERE project_id = ?"
                    " AND org_id = ?)",
                    (ts, ts, project_id, org_id))
                conn.execute(
                    "UPDATE reports SET deleted_at = ?, updated_at = ?"
                    " WHERE project_id = ? AND org_id = ? AND deleted_at IS NULL",
                    (ts, ts, project_id, org_id))
        return n > 0

    # -- files ------------------------------------------------------------
    def create_file(self, org_id: str, project_id: str, name: str, data: bytes,
                    *, file_type: str = "original", mime: str = "",
                    created_by: str = "", parent_file_id: Optional[str] = None,
                    kind: Optional[str] = None,
                    geometry: Optional[Any] = None) -> Dict[str, Any]:
        """Создать файл и его версию 1: blob → объектное хранилище, метаданные → БД."""
        if file_type not in FILE_TYPES:
            raise ValueError(
                f"file_type={file_type!r}: допустимы {', '.join(FILE_TYPES)}")
        file_id = new_id("file_")
        checksum = sha256_hex(data)
        version_kind = kind or _KIND_BY_FILE_TYPE.get(file_type, "original")
        key = build_storage_key(self.key_prefix, org_id, project_id, file_id, 1,
                                checksum, name)
        if self.storage is None:
            raise StorageError("Объектное хранилище не сконфигурировано")
        self.storage.put(key, data, mime or "application/octet-stream")
        ts = now_iso()
        version_id = new_id("ver_")
        try:
            with self.db.tx() as conn:
                conn.execute(
                    "INSERT INTO files (id, org_id, project_id, name, file_type,"
                    " source_kind, mime, size_bytes, checksum_sha256, storage_key,"
                    " version, parent_file_id, created_by, created_at, updated_at,"
                    " deleted_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,NULL)",
                    (file_id, org_id, project_id, name, file_type,
                     _SOURCE_KIND_BY_FILE_TYPE.get(file_type, "uploaded"), mime,
                     len(data), checksum, key, 1, parent_file_id, created_by,
                     ts, ts))
                conn.execute(
                    "INSERT INTO file_versions (id, file_id, org_id, version,"
                    " storage_key, checksum_sha256, size_bytes, mime, kind,"
                    " geometry, created_by, created_at, updated_at, deleted_at)"
                    " VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,NULL)",
                    (version_id, file_id, org_id, 1, key, checksum, len(data),
                     mime, version_kind,
                     json.dumps(geometry, ensure_ascii=False) if geometry else None,
                     created_by, ts, ts))
        except Exception:
            # Метаданные не записались — объект не должен остаться «сиротой».
            try:
                self.storage.delete(key)
            except StorageError:
                pass
            raise
        row = self.get_file(org_id, file_id)
        assert row is not None
        return row

    def get_file(self, org_id: str, file_id: str,
                 include_deleted: bool = False) -> Optional[Dict[str, Any]]:
        sql = "SELECT * FROM files WHERE id = ? AND org_id = ?"
        if not include_deleted:
            sql += " AND deleted_at IS NULL"
        with self.db.read() as conn:
            return conn.query_one(sql, (file_id, org_id))

    def list_files(self, org_id: str, project_id: str,
                   include_deleted: bool = False) -> List[Dict[str, Any]]:
        sql = ("SELECT * FROM files WHERE org_id = ? AND project_id = ?")
        if not include_deleted:
            sql += " AND deleted_at IS NULL"
        sql += " ORDER BY created_at ASC, id"
        with self.db.read() as conn:
            return conn.query(sql, (org_id, project_id))

    def list_versions(self, org_id: str, file_id: str,
                      include_deleted: bool = False) -> List[Dict[str, Any]]:
        sql = "SELECT * FROM file_versions WHERE org_id = ? AND file_id = ?"
        if not include_deleted:
            sql += " AND deleted_at IS NULL"
        sql += " ORDER BY version ASC"
        with self.db.read() as conn:
            return conn.query(sql, (org_id, file_id))

    def latest_version(self, org_id: str, file_id: str) -> Optional[Dict[str, Any]]:
        with self.db.read() as conn:
            return conn.query_one(
                "SELECT * FROM file_versions WHERE org_id = ? AND file_id = ?"
                " AND deleted_at IS NULL ORDER BY version DESC LIMIT 1",
                (org_id, file_id))

    def add_version(self, org_id: str, file_id: str, data: bytes, *,
                    mime: str = "", kind: str = "original", created_by: str = "",
                    name: Optional[str] = None,
                    geometry: Optional[Any] = None) -> Dict[str, Any]:
        """Добавить версию файла (blob + запись `file_versions`), обновить `files`."""
        current = self.get_file(org_id, file_id, include_deleted=True)
        if current is None:
            raise KeyError("file_not_found")
        project_id = current["project_id"]
        fname = name or current.get("name") or "file"
        checksum = sha256_hex(data)
        next_version = int(current.get("version") or 1) + 1
        key = build_storage_key(self.key_prefix, org_id, project_id, file_id,
                                next_version, checksum, fname)
        if self.storage is None:
            raise StorageError("Объектное хранилище не сконфигурировано")
        self.storage.put(key, data, mime or "application/octet-stream")
        ts = now_iso()
        version_id = new_id("ver_")
        with self.db.tx() as conn:
            conn.execute(
                "INSERT INTO file_versions (id, file_id, org_id, version,"
                " storage_key, checksum_sha256, size_bytes, mime, kind, geometry,"
                " created_by, created_at, updated_at, deleted_at)"
                " VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,NULL)",
                (version_id, file_id, org_id, next_version, key, checksum,
                 len(data), mime, kind,
                 json.dumps(geometry, ensure_ascii=False) if geometry else None,
                 created_by, ts, ts))
            conn.execute(
                "UPDATE files SET version = ?, size_bytes = ?, checksum_sha256 = ?,"
                " storage_key = ?, mime = COALESCE(NULLIF(?, ''), mime),"
                " updated_at = ? WHERE id = ? AND org_id = ?",
                (next_version, len(data), checksum, key, mime, ts, file_id, org_id))
        self._prune_versions(org_id, file_id)
        row = self.get_version(org_id, file_id, next_version)
        assert row is not None
        return row

    def get_version(self, org_id: str, file_id: str,
                    version: int) -> Optional[Dict[str, Any]]:
        with self.db.read() as conn:
            return conn.query_one(
                "SELECT * FROM file_versions WHERE org_id = ? AND file_id = ?"
                " AND version = ? AND deleted_at IS NULL",
                (org_id, file_id, int(version)))

    def _prune_versions(self, org_id: str, file_id: str) -> int:
        """Оставить последние `max_versions` версий (старые — soft delete + blob)."""
        with self.db.read() as conn:
            rows = conn.query(
                "SELECT id, version, storage_key FROM file_versions"
                " WHERE org_id = ? AND file_id = ? AND deleted_at IS NULL"
                " ORDER BY version DESC", (org_id, file_id))
        stale = rows[self.max_versions:]
        if not stale:
            return 0
        ts = now_iso()
        with self.db.tx() as conn:
            for row in stale:
                conn.execute(
                    "UPDATE file_versions SET deleted_at = ?, updated_at = ?"
                    " WHERE id = ? AND org_id = ?", (ts, ts, row["id"], org_id))
        for row in stale:
            key = row.get("storage_key")
            if key and self.storage is not None:
                try:
                    self.storage.delete(key)
                except StorageError:
                    pass  # объект мог быть уже удалён — не блокируем ответ
        return len(stale)

    def delete_file(self, org_id: str, file_id: str) -> bool:
        """Мягкое удаление файла: deleted_at + updated_at (версии помечаются)."""
        ts = now_iso()
        with self.db.tx() as conn:
            n = conn.execute(
                "UPDATE files SET deleted_at = ?, updated_at = ?"
                " WHERE id = ? AND org_id = ? AND deleted_at IS NULL",
                (ts, ts, file_id, org_id))
            if n:
                conn.execute(
                    "UPDATE file_versions SET deleted_at = ?, updated_at = ?"
                    " WHERE file_id = ? AND org_id = ? AND deleted_at IS NULL",
                    (ts, ts, file_id, org_id))
        return n > 0

    # -- reports ----------------------------------------------------------
    def create_report(self, org_id: str, project_id: str, kind: str, data: bytes,
                      *, file_id: Optional[str] = None, created_by: str = "",
                      mime: str = "", name: str = "") -> Dict[str, Any]:
        """Записать отчёт (PDF/XLSX/DXF) в хранилище + метаданные в `reports`."""
        if kind not in ("pdf", "xlsx", "dxf"):
            raise ValueError(f"kind={kind!r}: допустимы pdf, xlsx, dxf")
        rid = new_id("rep_")
        checksum = sha256_hex(data)
        fname = name or f"report.{kind}"
        key = (f"{self.key_prefix}/{org_id}/project/{project_id}/report/{rid}/"
               f"{checksum}/{fname}")
        if self.storage is None:
            raise StorageError("Объектное хранилище не сконфигурировано")
        self.storage.put(key, data, mime or "application/octet-stream")
        ts = now_iso()
        with self.db.tx() as conn:
            conn.execute(
                "INSERT INTO reports (id, org_id, project_id, file_id, kind,"
                " storage_key, checksum_sha256, size_bytes, created_by,"
                " generated_at, created_at, updated_at, deleted_at)"
                " VALUES (?,?,?,?,?,?,?,?,?,?,?,?,NULL)",
                (rid, org_id, project_id, file_id, kind, key, checksum, len(data),
                 created_by, ts, ts, ts))
        row = self.get_report(org_id, rid)
        assert row is not None
        return row

    def get_report(self, org_id: str, report_id: str) -> Optional[Dict[str, Any]]:
        with self.db.read() as conn:
            return conn.query_one(
                "SELECT * FROM reports WHERE id = ? AND org_id = ?"
                " AND deleted_at IS NULL", (report_id, org_id))

    def list_reports(self, org_id: str, project_id: str) -> List[Dict[str, Any]]:
        with self.db.read() as conn:
            return conn.query(
                "SELECT * FROM reports WHERE org_id = ? AND project_id = ?"
                " AND deleted_at IS NULL ORDER BY generated_at DESC, id",
                (project_id, org_id))

    def delete_report(self, org_id: str, report_id: str) -> bool:
        ts = now_iso()
        with self.db.tx() as conn:
            n = conn.execute(
                "UPDATE reports SET deleted_at = ?, updated_at = ?"
                " WHERE id = ? AND org_id = ? AND deleted_at IS NULL",
                (ts, ts, report_id, org_id))
        return n > 0

    # -- объекты ----------------------------------------------------------
    def read_object(self, key: str) -> bytes:
        if self.storage is None:
            raise StorageError("Объектное хранилище не сконфигурировано")
        return self.storage.get(key)

    def presigned_url(self, key: str, expires: int = 300,
                      download_name: Optional[str] = None) -> str:
        if self.storage is None:
            raise StorageError("Объектное хранилище не сконфигурировано")
        return self.storage.presigned_get_url(key, expires=expires,
                                              download_name=download_name)

    def object_exists(self, key: str) -> bool:
        if self.storage is None:
            return False
        return self.storage.exists(key)
