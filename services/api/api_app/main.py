# -*- coding: utf-8 -*-
"""Сервис `api` (control plane) SaaS «Препресс-Планер».

Основание: System Design v1 — ADR-5 (гибрид S3+PostgreSQL), ADR-6 (единый
origin, nginx), ADR-7 (конвертер отдельным сервисом, вызов только
сервер-к-серверу), §3.3/§3.4 (потоки и границы), §12.4/§12.5 (контракты
проектов и файлов), §13.3 (модель данных); PRD v2 F-1…F-4, N-4.

Что делает сервис:
  * хранит проекты и файлы организации: метаданные/версии — PostgreSQL (§13.3),
    blobs ≤ 50 МБ — S3-совместимое объектное хранилище по ключу
    `org/{org_id}/project/{project_id}/file/{file_id}/{version}/{sha256}/{name}`;
  * авторизует каждый запрос через `auth POST /auth/verify` и фильтрует ВСЕ
    выборки по `org_id` (row-level изоляция, N-4);
  * загружает файлы (multipart, ≤ PP_MAX_MB), считает sha256, версионирует;
  * при загрузке AI/CDR/EPS вызывает конвертер (8120, внутренний) и переносит
    результат в объектное хранилище отдельным файлом (`converter_result`);
  * отдаёт содержимое потоком через API (entitlement + org-изоляция) либо
    короткоживущим presigned URL;
  * мягко удаляет проекты/файлы (`deleted_at` + `updated_at`).

Публичные пути (nginx срезает префикс `/api`, ADR-6):
    POST   /api/projects                          → 201 {project_id, state, project}
    GET    /api/projects                          → {items, total}
    GET    /api/projects/{id}                     → {project, files, versions}
    PATCH  /api/projects/{id}                     → {project}
    DELETE /api/projects/{id}                     → 204 (soft delete)
    POST   /api/projects/{id}/files               → 201 {file_id, storage_key, checksum, file, version}
    GET    /api/projects/{id}/files               → {items, total}
    GET    /api/projects/{id}/files/{file_id}     → {file, versions}
    POST   /api/projects/{id}/files/{file_id}/convert → 202 {job_id} (ADR-7)
    DELETE /api/files/{file_id}                   → 204 (soft delete)
    GET    /api/files/{file_id}                   → метаданные файла
    GET    /api/files/{file_id}/download          → поток или ?mode=presigned
    GET    /api/files/{file_id}/content?format=svg|pdf
    GET    /api/projects/{id}/reports             → {items}
    GET    /api/reports/{id} | /api/reports/{id}/download
    GET    /api/jobs/{job_id}                     → статус фоновой конвертации
    POST   /api/projects/{id}/calc                → {calc: MaterialResult} (§12.6, F-10)
    POST   /api/projects/{id}/variants            → {variants: [...]} (§12.6, F-11)
    POST   /api/projects/{id}/teo                 → {teo: TeoResult} (§12.6, F-14)
    POST   /api/projects/{id}/teo/compare         → {comparison: …} (§12.6, F-15)
    POST   /api/projects/{id}/pipeline            → {state, result, reference} (§12.6)
    POST   /api/projects/{id}/calculate           → синоним /pipeline (UI-путь)
    POST   /api/projects/{id}/reports/{fmt}       → отчёт PDF/XLSX/DXF (§12.8)
    GET    /api/orgs/{org_id}/catalog | PUT       → PriceCatalog организации
    GET    /healthz

Совместимость путей: внутренний префикс `/api` и версия `/api/v1` (§12.4)
нормализуются middleware — `POST /api/v1/projects` и `POST /api/projects`
попадают в один обработчик (BD-пути `/api/v1/...` из промпта задачи и §12.4).
"""
from __future__ import annotations

import base64
import json
import threading
import uuid
from contextlib import asynccontextmanager
from typing import Any, Dict, List, Optional

from fastapi import (FastAPI, File, Form, Header, HTTPException, Path,
                     Query, Request, UploadFile)
from fastapi.responses import JSONResponse, Response
from pydantic import BaseModel, Field

from . import config as config_mod
from . import repo as repo_mod
from .auth import AuthError, require_role
from .converter import ConverterClient, ConverterError, is_closed_format
from .db import Database, DbError
from .domain import DomainClient, DomainError
from .entitlement import fetch_entitlement, projects_limit
from .storage import StorageError, build_storage

# --------------------------------------------------------------------------
# Состояние приложения (собирается в lifespan; тесты подменяют поля)
# --------------------------------------------------------------------------

STATE: Dict[str, Any] = {
    "config": None,
    "db": None,
    "storage": None,
    "repo": None,
    "converter": None,
    "domain": None,
    "jobs": {},
    "storage_status": "unknown",
}

# Расширения файлов API (F-1/F-2): локальный разбор + закрытые через конвертер.
ALLOWED_EXTENSIONS = (".dxf", ".svg", ".pdf", ".ai", ".cdr", ".eps")
CLOSED_EXTENSIONS = (".ai", ".cdr", ".eps")

_MIME_HINTS = {
    ".svg": ("image/svg+xml",),
    ".pdf": ("application/pdf",),
    ".ai": ("application/pdf", "application/postscript", "application/illustrator"),
    ".cdr": ("application/cdr", "application/x-cdr", "application/octet-stream",
             "image/x-cdr"),
    ".eps": ("application/postscript", "application/eps", "image/eps"),
    ".dxf": ("application/dxf", "image/vnd.dxf", "text/plain",
             "application/octet-stream", "application/x-dxf"),
}


def get_config():
    if STATE["config"] is None:
        raise RuntimeError("Сервис не инициализирован")
    return STATE["config"]


def get_repo() -> repo_mod.Repo:
    if STATE["repo"] is None:
        raise RuntimeError("Репозиторий не инициализирован")
    return STATE["repo"]


def _db() -> Database:
    if STATE["db"] is None:
        raise RuntimeError("БД не инициализирована")
    return STATE["db"]


def _converter() -> ConverterClient:
    if STATE["converter"] is None:
        raise RuntimeError("Клиент конвертера не инициализирован")
    return STATE["converter"]


def _domain() -> DomainClient:
    if STATE["domain"] is None:
        raise RuntimeError("Клиент домена (domain-worker) не инициализирован")
    return STATE["domain"]


# --------------------------------------------------------------------------
# Ошибки: единый конверт {"error": {code, message, details}} (§12.1), русский
# --------------------------------------------------------------------------

class ApiError(Exception):
    def __init__(self, status: int, code: str, message: str,
                 details: Any = None) -> None:
        super().__init__(message)
        self.status = status
        self.code = code
        self.message = message
        self.details = details


def error_response(status: int, code: str, message: str,
                   details: Any = None) -> JSONResponse:
    body: Dict[str, Any] = {"error": {"code": code, "message": message}}
    if details is not None:
        body["error"]["details"] = details
    return JSONResponse(status_code=status, content=body)


# --------------------------------------------------------------------------
# Модели запросов
# --------------------------------------------------------------------------

class ProjectCreate(BaseModel):
    name: str = Field(default="", description="Название проекта")
    org_id: Optional[str] = None
    state: Optional[Dict[str, Any]] = None


class ProjectPatch(BaseModel):
    name: Optional[str] = None
    state: Optional[Dict[str, Any]] = None


class CatalogBody(BaseModel):
    catalog: Dict[str, Any]


# --------------------------------------------------------------------------
# Жизненный цикл
# --------------------------------------------------------------------------

def build_runtime(cfg: Optional[config_mod.Config] = None) -> Dict[str, Any]:
    """Собрать БД/хранилище/клиентов по конфигурации (используется и тестами)."""
    cfg = cfg or config_mod.Config()
    database = Database(db_url=cfg.db_url, data_dir=cfg.data_dir)
    database.init_schema()
    storage = build_storage(cfg)
    status = "memory"
    if hasattr(storage, "bucket_status"):
        status = storage.bucket_status()
    runtime = {
        "config": cfg,
        "db": database,
        "storage": storage,
        "storage_status": status,
        "repo": repo_mod.Repo(database, storage, key_prefix=cfg.storage_prefix,
                              max_versions=cfg.max_file_versions),
        "converter": ConverterClient(cfg.converter_url, timeout=cfg.convert_timeout,
                                     poll_interval=cfg.convert_poll_interval),
        "domain": DomainClient(cfg.domain_worker_url, timeout=cfg.http_timeout),
        "jobs": {},
    }
    return runtime


@asynccontextmanager
async def _lifespan(app: FastAPI):  # noqa: ARG001
    if STATE["config"] is None:
        try:
            STATE.update(build_runtime())
        except (DbError, StorageError, RuntimeError) as exc:  # pragma: no cover
            STATE["startup_error"] = str(exc)
    yield


app = FastAPI(
    title="Препресс-Планер: API (проекты и файлы)",
    version="0.1.0",
    description="Control plane SaaS: проекты, файлы (S3+PostgreSQL), "
                "версии, конвертер (ADR-7), изоляция по организации (N-4).",
    lifespan=_lifespan,
)


@app.middleware("http")
async def _normalize_path(request: Request, call_next):
    """Принять и `/api/...`, и `/api/v1/...` (nginx срезает `/api`, ADR-6)."""
    path = request.scope.get("path") or "/"
    for prefix in ("/v1/", "/api/v1/", "/api/"):
        if path.startswith(prefix):
            path = "/" + path[len(prefix):]
            break
    else:
        if path in ("/api", "/api/v1", "/v1"):
            path = "/"
    request.scope["path"] = path
    return await call_next(request)


@app.exception_handler(AuthError)
async def _auth_error_handler(request: Request, exc: AuthError):  # noqa: ARG001
    return error_response(exc.status, exc.code, exc.message)


@app.exception_handler(ApiError)
async def _api_error_handler(request: Request, exc: ApiError):  # noqa: ARG001
    return error_response(exc.status, exc.code, exc.message, exc.details)


@app.exception_handler(ConverterError)
async def _converter_error_handler(request: Request, exc: ConverterError):  # noqa: ARG001
    return error_response(422, "converter_error", str(exc))


@app.exception_handler(DomainError)
async def _domain_error_handler(request: Request, exc: DomainError):  # noqa: ARG001
    return error_response(exc.status, exc.code, exc.message)


@app.exception_handler(StorageError)
async def _storage_error_handler(request: Request, exc: StorageError):  # noqa: ARG001
    return error_response(503, "storage_unavailable", str(exc))


@app.exception_handler(HTTPException)
async def _http_error_handler(request: Request, exc: HTTPException):  # noqa: ARG001
    message = exc.detail if isinstance(exc.detail, str) else "Ошибка запроса."
    return error_response(exc.status_code, "http_error", message)


# --------------------------------------------------------------------------
# Вспомогательные функции
# --------------------------------------------------------------------------

def _validate_name(name: str) -> str:
    value = (name or "").strip()
    if not value:
        raise ApiError(422, "invalid_name", "Укажите название проекта.")
    if len(value) > 200:
        raise ApiError(422, "invalid_name",
                       "Название проекта длиннее 200 символов.")
    return value


def _ext_of(file_name: str) -> str:
    base = (file_name or "").rsplit("/", 1)[-1].rsplit("\\", 1)[-1]
    dot = base.rfind(".")
    return base[dot:].lower() if dot >= 0 else ""


def _validate_upload(file_name: str, content_type: str) -> str:
    """Проверить расширение и content-type (F-1…F-4). Вернуть расширение."""
    ext = _ext_of(file_name)
    if not ext:
        raise ApiError(422, "unsupported_format",
                       "Не удалось определить формат: у файла нет расширения. "
                       "Допустимы DXF, SVG, PDF, AI, CDR, EPS.")
    if ext not in ALLOWED_EXTENSIONS:
        raise ApiError(
            422, "unsupported_format",
            f"Формат {ext} не поддерживается. Допустимы: "
            + ", ".join(e.lstrip(".").upper() for e in ALLOWED_EXTENSIONS) + ".")
    ctype = (content_type or "").split(";")[0].strip().lower()
    if ctype and ctype not in ("application/octet-stream", "binary/octet-stream"):
        allowed = _MIME_HINTS.get(ext, ())
        if allowed and ctype not in allowed and not ctype.startswith("image/"):
            raise ApiError(
                422, "content_type_mismatch",
                f"Content-type {ctype} не соответствует расширению {ext}. "
                "Проверьте, что загружается нужный файл.")
    return ext


def _read_upload(upload: UploadFile, max_bytes: int) -> bytes:
    """Прочитать тело загрузки с лимитом (413 вместо «тихой» обрезки)."""
    chunks: List[bytes] = []
    total = 0
    while True:
        chunk = upload.file.read(1024 * 1024)
        if not chunk:
            break
        total += len(chunk)
        if total > max_bytes:
            limit_mb = max_bytes / (1024 * 1024)
            raise ApiError(
                413, "file_too_large",
                f"Файл больше {limit_mb:g} МБ — загрузка не выполняется "
                "(лимит PP_MAX_MB).")
        chunks.append(chunk)
    data = b"".join(chunks)
    if not data:
        raise ApiError(422, "empty_file", "Файл пустой — нечего загружать.")
    return data


def _project_or_404(org_id: str, project_id: str) -> Dict[str, Any]:
    row = get_repo().get_project(org_id, project_id)
    if row is None:
        raise ApiError(404, "project_not_found",
                       "Проект не найден или недоступен для этой организации.")
    return row


def _file_or_404(org_id: str, file_id: str) -> Dict[str, Any]:
    row = get_repo().get_file(org_id, file_id)
    if row is None:
        raise ApiError(404, "file_not_found",
                       "Файл не найден или недоступен для этой организации.")
    return row


def _entitlement_for(config, token: str, org_id: str) -> Optional[Dict[str, Any]]:
    if not config.entitlement_enforce:
        return None
    return fetch_entitlement(config.billing_url, token, org_id,
                             timeout=config.http_timeout)


def _http_status_code(status: int) -> bool:
    return 200 <= status < 300


# --------------------------------------------------------------------------
# Health
# --------------------------------------------------------------------------

@app.get("/healthz")
def healthz() -> Dict[str, Any]:
    cfg = STATE.get("config")
    out: Dict[str, Any] = {"status": "ok", "service": "api", "version": app.version}
    if cfg is None:
        out["status"] = "degraded"
        out["startup_error"] = STATE.get("startup_error", "инициализация не выполнена")
        return out
    out.update(cfg.describe())
    db = STATE.get("db")
    out["db"] = db.describe() if db is not None else "не инициализирована"
    out["db_kind"] = db.kind if db is not None else None
    out["storage_status"] = STATE.get("storage_status")
    out["storage"] = getattr(STATE.get("storage"), "name", None)
    out["auth_required"] = cfg.auth_required
    out["tables"] = db.tables() if db is not None else []
    return out


# --------------------------------------------------------------------------
# Проекты (§12.4)
# --------------------------------------------------------------------------

@app.post("/projects", status_code=201)
def create_project(body: ProjectCreate,
                   request: Request,
                   authorization: Optional[str] = Header(default=None)) -> Dict[str, Any]:
    """Создать проект организации (Bearer; org берётся из auth/verify)."""
    cfg = get_config()
    principal, membership = require_role(cfg, authorization, body.org_id, "member")
    name = _validate_name(body.name)
    if get_repo().project_name_exists(membership.org_id, name):
        raise ApiError(409, "project_exists",
                       f"Проект «{name}» уже существует — выберите "
                       "другое название.")
    token = (authorization or "")[7:].strip()
    ent = _entitlement_for(cfg, token, membership.org_id)
    limit = projects_limit(ent)
    if limit is not None and get_repo().count_projects(membership.org_id) >= limit:
        raise ApiError(
            403, "plan_limit",
            f"Тариф ограничивает число проектов ({limit}). "
            "Оформите подписку Pro, чтобы создавать больше проектов.",
            {"limit": limit})
    row = get_repo().create_project(membership.org_id, name, principal.user_id,
                                    body.state)
    project = repo_mod.project_json(row)
    return {"project_id": row["id"], "state": project["state"],
            "project": project, "org_id": membership.org_id}


@app.get("/projects")
def list_projects(request: Request,
                  org_id: Optional[str] = Query(default=None),
                  limit: int = Query(default=200, ge=1, le=500),
                  offset: int = Query(default=0, ge=0),
                  authorization: Optional[str] = Header(default=None)) -> Dict[str, Any]:
    cfg = get_config()
    _, membership = require_role(cfg, authorization, org_id, "viewer")
    rows = get_repo().list_projects(membership.org_id, limit=limit, offset=offset)
    return {
        "items": [repo_mod.project_json(r) for r in rows],
        "total": get_repo().count_projects(membership.org_id),
        "org_id": membership.org_id,
        "limit": limit,
        "offset": offset,
    }


@app.get("/projects/{project_id}")
def get_project(project_id: str = Path(...),
                org_id: Optional[str] = Query(default=None),
                authorization: Optional[str] = Header(default=None)) -> Dict[str, Any]:
    cfg = get_config()
    _, membership = require_role(cfg, authorization, org_id, "viewer")
    row = _project_or_404(membership.org_id, project_id)
    files = get_repo().list_files(membership.org_id, project_id)
    versions: List[Dict[str, Any]] = []
    for f in files:
        versions.extend(repo_mod.version_json(v)
                        for v in get_repo().list_versions(membership.org_id, f["id"]))
    return {
        "project": repo_mod.project_json(row),
        "files": [repo_mod.file_json(f) for f in files],
        "versions": versions,
    }


@app.patch("/projects/{project_id}")
def patch_project(body: ProjectPatch,
                  project_id: str = Path(...),
                  authorization: Optional[str] = Header(default=None)) -> Dict[str, Any]:
    cfg = get_config()
    _, membership = require_role(cfg, authorization, None, "member")
    row = _project_or_404(membership.org_id, project_id)
    if body.name is not None:
        new_name = _validate_name(body.name)
        if (new_name != row["name"] and get_repo().project_name_exists(
                membership.org_id, new_name, exclude_id=project_id)):
            raise ApiError(409, "project_exists",
                           f"Проект «{new_name}» уже существует — выберите "
                           "другое название.")
        if not get_repo().rename_project(membership.org_id, project_id,
                                         new_name):
            raise ApiError(404, "project_not_found", "Проект не найден.")
    if body.state is not None:
        get_repo().put_project_state(membership.org_id, project_id, body.state)
    row = _project_or_404(membership.org_id, project_id)
    return {"project": repo_mod.project_json(row)}


@app.delete("/projects/{project_id}", status_code=204)
def delete_project(project_id: str = Path(...),
                   authorization: Optional[str] = Header(default=None)) -> Response:
    """Мягкое удаление: `deleted_at` + `updated_at` (blobs сохраняются)."""
    cfg = get_config()
    _, membership = require_role(cfg, authorization, None, "admin")
    if not get_repo().delete_project(membership.org_id, project_id):
        raise ApiError(404, "project_not_found", "Проект не найден.")
    return Response(status_code=204)


# --------------------------------------------------------------------------
# Файлы (§12.5, F-1…F-4)
# --------------------------------------------------------------------------

@app.post("/projects/{project_id}/files", status_code=201)
async def upload_file(project_id: str = Path(...),
                      file: UploadFile = File(...),
                      convert: Optional[str] = Form(default=None),
                      convert_target: str = Form(default="svg"),
                      file_type: str = Form(default="original"),
                      org_id: Optional[str] = Form(default=None),
                      authorization: Optional[str] = Header(default=None)) -> Dict[str, Any]:
    """Загрузка файла (multipart, ≤ PP_MAX_MB) в объектное хранилище.

    Для AI/CDR/EPS (или `convert=1`) дополнительно запускается конвертация
    сервер-к-серверу (ADR-7) — результат станет отдельным файлом
    `converter_result` со своей версией.
    """
    cfg = get_config()
    principal, membership = require_role(cfg, authorization, org_id, "member")
    _project_or_404(membership.org_id, project_id)

    original_name = (file.filename or "").strip()
    ext = _validate_upload(original_name, file.content_type or "")
    data = _read_upload(file, cfg.max_upload_bytes)

    want_convert = (convert in ("1", "true", "yes", "svg", "pdf")) or is_closed_format(original_name)
    target = (convert if convert in ("svg", "pdf") else convert_target or "svg").lower()
    if want_convert and target not in ("svg", "pdf"):
        raise ApiError(422, "invalid_target", "Целевой формат конвертации: svg или pdf.")
    if target not in ("svg", "pdf"):
        target = "svg"

    repo = get_repo()
    row = repo.create_file(
        membership.org_id, project_id, original_name, data,
        file_type=file_type if file_type in repo_mod.FILE_TYPES else "original",
        mime=(file.content_type or "").split(";")[0].strip(),
        created_by=principal.user_id)
    version = repo.latest_version(membership.org_id, row["id"]) or {}

    payload: Dict[str, Any] = {
        "file_id": row["id"],
        "storage_key": row["storage_key"],
        "checksum": row["checksum_sha256"],
        "version": row["version"],
        "file": repo_mod.file_json(row),
        "first_version": repo_mod.version_json(version) if version else None,
        "org_id": membership.org_id,
        "converted": False,
    }
    if want_convert:
        if convert in ("svg", "pdf"):
            job = _run_conversion_sync(membership.org_id, project_id, row, data,
                                       target, principal.user_id)
            payload.update(job)
        else:
            job_id = _start_conversion_async(membership.org_id, project_id, row,
                                             data, target, principal.user_id)
            payload.update({"converted": True, "async": True, "job_id": job_id,
                            "job_status_url": f"/api/jobs/{job_id}"})
    return payload


def _convert_payload(parent: Dict[str, Any], converted: Dict[str, Any],
                     target: str, converter_status: str) -> Dict[str, Any]:
    """Ответ по результату конвертации (ADR-7): новый файл + ссылка на исходник."""
    return {
        "converted": True,
        "async": False,
        "converter_status": converter_status,
        "target": target,
        "converted_file_id": converted["id"],
        "converted_storage_key": converted["storage_key"],
        "converted_checksum": converted["checksum_sha256"],
        "converted_file": repo_mod.file_json(converted),
        "parent_file_id": parent["id"],
    }


def _run_conversion_sync(org_id: str, project_id: str, parent: Dict[str, Any],
                         data: bytes, target: str,
                         user_id: str) -> Dict[str, Any]:
    """Конвертировать в текущем запросе (клиент ждёт результат)."""
    name = parent.get("name") or "file"
    body, mime = _converter().convert(name, data, target)
    converted = _store_converted(org_id, project_id, parent, body, mime, target,
                                 user_id)
    return _convert_payload(parent, converted, target, "done")


def _start_conversion_async(org_id: str, project_id: str, parent: Dict[str, Any],
                            data: bytes, target: str, user_id: str) -> str:
    """Конвертировать в фоне (крупный макет не упирается в таймаут nginx)."""
    job_id = "job_" + uuid.uuid4().hex[:16]
    STATE["jobs"][job_id] = {
        "job_id": job_id,
        "org_id": org_id,
        "project_id": project_id,
        "file_id": parent["id"],
        "target": target,
        "status": "pending",
        "result": None,
        "error": None,
        "created_at": repo_mod.now_iso(),
    }

    def _worker() -> None:
        job = STATE["jobs"][job_id]
        job["status"] = "running"
        try:
            body, mime = _converter().convert(parent.get("name") or "file", data,
                                              target)
            converted = _store_converted(org_id, project_id, parent, body, mime,
                                        target, user_id)
            job["status"] = "done"
            job["result"] = _convert_payload(parent, converted, target, "done")
        except ConverterError as exc:
            job["status"] = "error"
            job["error"] = str(exc)
        except Exception as exc:  # noqa: BLE001 - фоновая задача не должна падать
            job["status"] = "error"
            job["error"] = f"Внутренняя ошибка конвертации: {exc}"

    threading.Thread(target=_worker, daemon=True).start()
    return job_id


def _store_converted(org_id: str, project_id: str, parent: Dict[str, Any],
                     body: bytes, mime: str, target: str,
                     user_id: str) -> Dict[str, Any]:
    """Перенести результат конвертации в объектное хранилище (ADR-5/ADR-7)."""
    base = (parent.get("name") or "file").rsplit(".", 1)[0]
    name = f"{base}.{target}"
    return get_repo().create_file(
        org_id, project_id, name, body, file_type="converter_result", mime=mime,
        created_by=user_id, parent_file_id=parent["id"])


@app.get("/projects/{project_id}/files")
def list_project_files(project_id: str = Path(...),
                       org_id: Optional[str] = Query(default=None),
                       authorization: Optional[str] = Header(default=None)) -> Dict[str, Any]:
    cfg = get_config()
    _, membership = require_role(cfg, authorization, org_id, "viewer")
    _project_or_404(membership.org_id, project_id)
    rows = get_repo().list_files(membership.org_id, project_id)
    return {"items": [repo_mod.file_json(r) for r in rows],
            "total": len(rows), "project_id": project_id}


@app.get("/projects/{project_id}/files/{file_id}")
def get_file_meta(project_id: str = Path(...), file_id: str = Path(...),
                  org_id: Optional[str] = Query(default=None),
                  authorization: Optional[str] = Header(default=None)) -> Dict[str, Any]:
    cfg = get_config()
    _, membership = require_role(cfg, authorization, org_id, "viewer")
    row = _file_or_404(membership.org_id, file_id)
    if row["project_id"] != project_id:
        raise ApiError(404, "file_not_found",
                       "Файл не найден в указанном проекте.")
    versions = get_repo().list_versions(membership.org_id, file_id)
    return {"file": repo_mod.file_json(row),
            "versions": [repo_mod.version_json(v) for v in versions]}


@app.get("/files/{file_id}")
def get_file(file_id: str = Path(...),
             org_id: Optional[str] = Query(default=None),
             authorization: Optional[str] = Header(default=None)) -> Dict[str, Any]:
    """Метаданные файла (содержимое — только через /download или /content)."""
    cfg = get_config()
    _, membership = require_role(cfg, authorization, org_id, "viewer")
    row = _file_or_404(membership.org_id, file_id)
    versions = get_repo().list_versions(membership.org_id, file_id)
    return {"file": repo_mod.file_json(row),
            "versions": [repo_mod.version_json(v) for v in versions]}


@app.delete("/files/{file_id}", status_code=204)
def delete_file(file_id: str = Path(...),
                authorization: Optional[str] = Header(default=None)) -> Response:
    """Мягкое удаление файла: `deleted_at` + `updated_at` (blob сохраняется)."""
    cfg = get_config()
    _, membership = require_role(cfg, authorization, None, "member")
    if not get_repo().delete_file(membership.org_id, file_id):
        raise ApiError(404, "file_not_found", "Файл не найден.")
    return Response(status_code=204)


def _content_response(org_id: str, file_id: str, version: Optional[int],
                      mode: str, download: bool = False) -> Response:
    """Отдать содержимое: поток через API либо presigned URL (ADR-5, §4)."""
    cfg = get_config()
    repo = get_repo()
    row = _file_or_404(org_id, file_id)
    if version is None:
        ver = repo.latest_version(org_id, file_id)
    else:
        ver = repo.get_version(org_id, file_id, version)
    if ver is None:
        raise ApiError(404, "version_not_found", "Версия файла не найдена.")
    key = ver["storage_key"]
    name = row.get("name") or "file"
    mime = ver.get("mime") or "application/octet-stream"
    if mode == "presigned":
        url = repo.presigned_url(key, expires=cfg.presign_ttl,
                                 download_name=name if download else None)
        return JSONResponse({
            "mode": "presigned",
            "url": url,
            "expires_in": cfg.presign_ttl,
            "file_id": file_id,
            "version": int(ver["version"]),
            "name": name,
            "checksum_sha256": ver["checksum_sha256"],
            "size_bytes": int(ver.get("size_bytes") or 0),
        })
    body = repo.read_object(key)
    headers = {
        "Content-Type": mime,
        "Content-Length": str(len(body)),
        "X-PP-Checksum-Sha256": ver["checksum_sha256"] or "",
        "Cache-Control": "private, max-age=0, no-store",
    }
    if download:
        headers["Content-Disposition"] = f'attachment; filename="{name}"'
    return Response(content=body, media_type=mime, headers=headers)


@app.get("/files/{file_id}/download")
def download_file(file_id: str = Path(...),
                  mode: str = Query(default="stream",
                                    description="stream (по умолчанию) | presigned"),
                  version: Optional[int] = Query(default=None, ge=1),
                  org_id: Optional[str] = Query(default=None),
                  authorization: Optional[str] = Header(default=None)) -> Response:
    """Скачать содержимое файла (проверка entitlement + org-изоляция)."""
    cfg = get_config()
    _, membership = require_role(cfg, authorization, org_id, "viewer")
    token = (authorization or "")[7:].strip()
    if cfg.entitlement_enforce:
        ent = fetch_entitlement(cfg.billing_url, token, membership.org_id,
                                timeout=cfg.http_timeout)
        # billing недоступен → не блокируем (fail-open, см. entitlement.py).
        if ent is not None and ent.get("pro") is False:
            features = ent.get("features") or {}
            if features.get("reports") is False and _looks_like_report(membership.org_id, file_id):
                raise ApiError(403, "plan_limit",
                               "Скачивание отчётов доступно на тарифе Pro.")
    if mode not in ("stream", "presigned"):
        raise ApiError(422, "invalid_mode",
                       "Режим скачивания: stream или presigned.")
    return _content_response(membership.org_id, file_id, version, mode,
                             download=True)


@app.get("/files/{file_id}/content")
def file_content(file_id: str = Path(...),
                 format: str = Query(default="", description="svg|pdf|original"),
                 mode: str = Query(default="stream"),
                 version: Optional[int] = Query(default=None, ge=1),
                 org_id: Optional[str] = Query(default=None),
                 authorization: Optional[str] = Header(default=None)) -> Response:
    """Содержимое конкретной версии: `format=svg|pdf` (конвертированная) или original."""
    cfg = get_config()
    _, membership = require_role(cfg, authorization, org_id, "viewer")
    fmt = (format or "").lower()
    if fmt not in ("", "svg", "pdf", "original"):
        raise ApiError(422, "invalid_format",
                       "Формат содержимого: svg, pdf или original.")
    if fmt in ("svg", "pdf"):
        versions = get_repo().list_versions(membership.org_id, file_id)
        wanted = [v for v in versions if (v.get("kind") == "converted"
                                          and (v.get("mime") or "").endswith(fmt))
                  or (v.get("storage_key") or "").lower().endswith("." + fmt)]
        if not wanted:
            raise ApiError(
                404, "converted_not_found",
                f"Конвертированная версия ({fmt}) не найдена — "
                "сначала выполните конвертацию файла.")
        version = int(wanted[-1]["version"])
    if mode not in ("stream", "presigned"):
        raise ApiError(422, "invalid_mode", "Режим: stream или presigned.")
    return _content_response(membership.org_id, file_id, version, mode)


def _looks_like_report(org_id: str, file_id: str) -> bool:
    row = get_repo().get_file(org_id, file_id)
    return bool(row and row.get("file_type") == "report")


@app.post("/projects/{project_id}/files/{file_id}/convert", status_code=202)
def convert_file(project_id: str = Path(...), file_id: str = Path(...),
                 target: str = Query(default="svg"),
                 sync: Optional[str] = Query(default=None),
                 authorization: Optional[str] = Header(default=None)) -> Dict[str, Any]:
    """Серверная конвертация закрытого формата (ADR-7): результат — новая версия.

    По умолчанию запускается асинхронно (`202 {job_id}`), `?sync=1` —
    синхронно (укладывается в таймаут nginx 220 с, §12.6).
    """
    cfg = get_config()
    principal, membership = require_role(cfg, authorization, None, "member")
    row = _file_or_404(membership.org_id, file_id)
    if row["project_id"] != project_id:
        raise ApiError(404, "file_not_found", "Файл не найден в указанном проекте.")
    target = (target or "svg").lower()
    if target not in ("svg", "pdf"):
        raise ApiError(422, "invalid_target", "Целевой формат: svg или pdf.")
    if not is_closed_format(row.get("name") or ""):
        raise ApiError(
            422, "not_convertible",
            f"Файл «{row.get('name')}» не требует конвертации: "
            "допустимы AI, CDR, EPS.")
    ver = get_repo().latest_version(membership.org_id, file_id)
    if ver is None:
        raise ApiError(404, "version_not_found", "Версия файла не найдена.")
    data = get_repo().read_object(ver["storage_key"])
    if sync in ("1", "true", "yes"):
        return _run_conversion_sync(membership.org_id, project_id, row, data,
                                    target, principal.user_id)
    job_id = _start_conversion_async(membership.org_id, project_id, row, data,
                                     target, principal.user_id)
    return {"job_id": job_id, "status": "pending",
            "job_status_url": f"/api/jobs/{job_id}", "target": target}


@app.get("/jobs/{job_id}")
def get_job(job_id: str = Path(...),
            authorization: Optional[str] = Header(default=None)) -> Dict[str, Any]:
    """Статус фоновой конвертации (паттерн `GET /convert/{id}`, §12.1)."""
    cfg = get_config()
    _, membership = require_role(cfg, authorization, None, "viewer")
    job = STATE["jobs"].get(job_id)
    if job is None or job.get("org_id") != membership.org_id:
        raise ApiError(404, "job_not_found", "Задача не найдена.")
    return {
        "job_id": job_id,
        "status": job.get("status"),
        "result": job.get("result"),
        "error": job.get("error"),
        "target": job.get("target"),
        "file_id": job.get("file_id"),
        "project_id": job.get("project_id"),
    }


# --------------------------------------------------------------------------
# Доменные расчёты (§12.6) — через `domain-worker` (ADR-2, §3.3 С5)
#
# `api` не исполняет домен сам: он проверяет членство/роль, при необходимости
# подставляет байты объекта из хранилища (`file_version_id`) и вызывает
# `domain-worker POST /calculate` сервер-к-серверу. Ответ воркера — канонический
# `project_state.json v2`, 1:1 с `app/lib/src/projects/project.dart`.
# --------------------------------------------------------------------------

class LayoutParamsBody(BaseModel):
    """`layout_params` (§12.6): snake_case, как в контракте; camelCase тоже принят."""
    label_w: Optional[float] = None
    label_h: Optional[float] = None
    gap_x: Optional[float] = None
    gap_y: Optional[float] = None
    z_teeth: Optional[int] = None
    cp: Optional[float] = None
    rapport_manual: Optional[float] = None
    cyl_width: Optional[float] = None
    web_width: Optional[float] = None
    undercut: Optional[float] = None
    min_gap: Optional[float] = None
    mode: Optional[str] = None
    count: Optional[int] = None
    length: Optional[float] = None

    model_config = {"extra": "allow"}


class CalculationBody(BaseModel):
    """Тело запросов расчёта (§12.6)."""
    layout_params: Optional[Dict[str, Any]] = None
    teo_input: Optional[Dict[str, Any]] = None
    catalog: Optional[Dict[str, Any]] = None
    file_version_id: Optional[str] = None
    file_id: Optional[str] = None
    limit: Optional[int] = None
    stages: Optional[List[str]] = None
    name: Optional[str] = None

    model_config = {"extra": "allow"}


def _stage_names(stages: Optional[List[str]]) -> List[str]:
    if not stages:
        return ["calc"]
    out: List[str] = []
    for stage in stages:
        value = str(stage or "").strip().lower()
        if value in ("all", "full", "calculate", "calculation"):
            return ["all"]
        if value and value not in out:
            out.append(value)
    return out or ["calc"]


def _file_bytes_for_domain(org_id: str, body: CalculationBody
                           ) -> tuple:
    """Байты макета для домена из `file_version_id`/`file_id` (§12.6, F-1).

    Возвращает `(base64-строка, имя файла)`. Если версия не указана — расчёт
    идёт только по параметрам раскроя (эталонный сценарий PRD §10.2).
    """
    if body.file_version_id:
        return _version_bytes(org_id, body.file_version_id)
    if body.file_id:
        row = get_repo().get_file(org_id, body.file_id)
        if row is None:
            raise ApiError(404, "file_not_found",
                           "Файл не найден или недоступен для этой организации.")
        versions = get_repo().list_versions(org_id, body.file_id)
        if not versions:
            raise ApiError(404, "version_not_found", "У файла нет версий.")
        return _version_bytes(org_id, versions[-1])
    return None, ""


def _version_bytes(org_id: str, ref: Any) -> tuple:
    """Прочитать объект версии (по словарю версии или по идентификатору)."""
    version: Optional[Dict[str, Any]] = None
    if isinstance(ref, dict):
        version = ref
    else:
        version = _find_version(org_id, str(ref))
    if version is None:
        raise ApiError(404, "version_not_found",
                       "Версия файла не найдена или недоступна для этой организации.")
    data = get_repo().read_object(version["storage_key"])
    name = (version.get("name") or version.get("original_name")
            or version.get("storage_key", "layout").rsplit("/", 1)[-1]
            or "layout.dxf")
    return base64.b64encode(data).decode("ascii"), name


def _find_version(org_id: str, ref: str) -> Optional[Dict[str, Any]]:
    """Найти версию по `file_version_id` (id) либо по паре «file_id:version»."""
    file_id, _, raw_version = ref.partition(":")
    if raw_version:
        base = get_repo().get_file(org_id, file_id)
        if base is None:
            return None
        try:
            return get_repo().get_version(org_id, file_id, int(raw_version))
        except ValueError:
            return None
    base = get_repo().get_file(org_id, ref)
    if base is not None:
        versions = get_repo().list_versions(org_id, ref)
        return versions[-1] if versions else None
    return None


def _project_catalog(org_id: str, project_id: str,
                     override: Optional[Dict[str, Any]]) -> Optional[Dict[str, Any]]:
    """Каталог цен организации (§12.7); явный `catalog` в запросе важнее."""
    if override:
        return override
    rows = get_repo().get_project(org_id, project_id)
    state = repo_mod.parse_state(rows.get("state_json")) if rows else {}
    catalog = state.get("catalog")
    return catalog if isinstance(catalog, dict) else None


def _domain_calculate(membership, project_id: str, body: CalculationBody,
                      stages: List[str], *, need: str = "member",
                      name: str = "") -> Dict[str, Any]:
    """Проверить проект/роль, собрать запрос и вызвать `domain-worker` (§12.6)."""
    _project_or_404(membership.org_id, project_id)
    file_base64, file_name = _file_bytes_for_domain(membership.org_id, body)
    payload = _domain().build_payload(
        stages=tuple(stages),
        name=body.name or name or f"Проект {project_id}",
        params=body.layout_params,
        teo_input=body.teo_input,
        catalog=_project_catalog(membership.org_id, project_id, body.catalog),
        file_base64=file_base64,
        file_name=file_name,
        variants_limit=body.limit or 10,
        include_raw_paths=False,
    )
    return _domain().calculate(payload)


def _pipeline_state(result: Dict[str, Any]) -> Dict[str, Any]:
    """Состояние проекта v2 из ответа воркера (ключ `state` либо сам ответ)."""
    state = result.get("state")
    if isinstance(state, dict) and state:
        return state
    return result


def _stage_result(result: Dict[str, Any], stage: str) -> Optional[Dict[str, Any]]:
    stages = result.get("stageResults")
    if isinstance(stages, dict) and isinstance(stages.get(stage), dict):
        return stages[stage]
    return None


@app.post("/projects/{project_id}/pipeline")
def run_pipeline(project_id: str = Path(...),
                 body: CalculationBody = CalculationBody(),
                 org_id: Optional[str] = Query(default=None),
                 authorization: Optional[str] = Header(default=None)) -> Dict[str, Any]:
    """Полная доменная цепочка «импорт → … → ТЭО» (§12.6, §3.3 С5).

    Если передан макет (`file_version_id`/`file_id`), считаются все стадии
    (`all`: parse → analyze → heal → pattern → calc → variants → teo). Без
    макета — расчётная часть цепочки (`calc → variants → teo`): эталонный
    сценарий PRD §10.2 задаётся только параметрами раскроя.
    """
    cfg = get_config()
    _, membership = require_role(cfg, authorization, org_id, "member")
    has_geometry = bool(body.file_version_id or body.file_id)
    stages = ["all"] if has_geometry else ["calc", "variants", "teo"]
    result = _domain_calculate(membership, project_id, body, stages,
                               name="Полный расчёт")
    state = _pipeline_state(result)
    return {"project_id": project_id, "state": state, "result": result,
            "metrics": result.get("metrics", {}),
            "reference": (result.get("metrics") or {}).get("reference")}


@app.post("/projects/{project_id}/calculate")
def run_calculate(project_id: str = Path(...),
                  body: CalculationBody = CalculationBody(),
                  org_id: Optional[str] = Query(default=None),
                  authorization: Optional[str] = Header(default=None)) -> Dict[str, Any]:
    """Синоним `/pipeline` (UI-путь «рассчитать проект», §12.6)."""
    return run_pipeline(project_id=project_id, body=body, org_id=org_id,
                        authorization=authorization)


class ReportBody(CalculationBody):
    """Тело запроса отчёта (§12.8): поля расчёта + отчётные."""
    font_base64: Optional[str] = Field(
        default=None, description="DejaVuSans.ttf в base64 — кириллица PDF")
    paths: Optional[str] = Field(
        default=None, description="Для dxf: master (по умолчанию) | array")
    state: Optional[Dict[str, Any]] = Field(
        default=None, description="project_state.json v2 (геометрия для DXF)")


@app.post("/projects/{project_id}/reports/{fmt}")
def generate_report(project_id: str = Path(...),
                    fmt: str = Path(...),
                    body: ReportBody = ReportBody(),
                    org_id: Optional[str] = Query(default=None),
                    authorization: Optional[str] = Header(default=None)) -> Dict[str, Any]:
    """Сгенерировать отчёт PDF/XLSX/DXF (§12.8, F-16…F-18).

    Путь: `domain-worker` `POST /reports` (цепочка + генерация в изоляте,
    ADR-2) → объектное хранилище (ADR-5) → строка `reports`. Скачивание —
    `GET /api/reports/{id}/download`. Тело как у расчёта (`layout_params`,
    `teo_input`, `file_version_id`…), плюс `font_base64` (кириллица PDF),
    `paths` (dxf: master|array) и `state` (состояние проекта с геометрией).
    """
    cfg = get_config()
    principal, membership = require_role(cfg, authorization, org_id, "member")
    fmt = (fmt or "").strip().lower()
    if fmt not in ("pdf", "xlsx", "dxf"):
        raise ApiError(422, "invalid_format", "Формат отчёта: pdf, xlsx или dxf.")
    _project_or_404(membership.org_id, project_id)

    state = body.state if isinstance(body.state, dict) else None
    has_geometry = bool(body.file_version_id or body.file_id) or bool(
        state and state.get("rawPaths"))
    stages = ["all"] if has_geometry else ["calc", "variants", "teo"]
    file_base64, file_name = _file_bytes_for_domain(membership.org_id, body)
    report: Dict[str, Any] = {
        "format": fmt,
        "paths": (body.paths or "master").strip().lower(),
    }
    if body.font_base64:
        report["fontBase64"] = body.font_base64
    payload = _domain().build_payload(
        stages=tuple(stages),
        name=body.name or f"Отчёт {fmt.upper()}",
        params=body.layout_params,
        teo_input=body.teo_input,
        catalog=_project_catalog(membership.org_id, project_id, body.catalog),
        file_base64=file_base64,
        file_name=file_name,
        variants_limit=body.limit or 10,
        include_raw_paths=False,
        state=state,
        report=report,
    )
    # Отчёт (включая PDF со шрифтом) — дольше обычного расчёта.
    result = _domain().reports(payload, timeout=max(cfg.http_timeout, 120.0))
    rep = _stage_result(result, "report")
    # Контракт воркера — camelCase (`report_stage.dart`): contentBase64/mime/name.
    content = rep.get("contentBase64") if isinstance(rep, dict) else None
    if not content:
        raise ApiError(502, "domain_bad_response",
                       "Сервис расчётов не вернул отчёт.")
    data = base64.b64decode(content)
    row = get_repo().create_report(
        membership.org_id, project_id, fmt, data,
        created_by=principal.user_id,
        mime=str(rep.get("mime") or ""),
        name=str(rep.get("name") or ""))
    return {
        "project_id": project_id,
        "report": repo_mod.report_json(row),
        "download": f"/reports/{row['id']}/download",
    }


@app.post("/projects/{project_id}/calc")
def run_calc(project_id: str = Path(...),
             body: CalculationBody = CalculationBody(),
             org_id: Optional[str] = Query(default=None),
             authorization: Optional[str] = Header(default=None)) -> Dict[str, Any]:
    """`{layout_params, file_version_id?}` → `{calc: MaterialResult}` (§12.6, F-10)."""
    cfg = get_config()
    _, membership = require_role(cfg, authorization, org_id, "member")
    stages = _stage_names(body.stages) if body.stages else ["calc"]
    if "calc" not in stages and stages != ["all"]:
        stages = ["calc"]
    result = _domain_calculate(membership, project_id, body, stages, name="Раскрой")
    calc = _stage_result(result, "calc")
    if calc is None:
        raise ApiError(502, "domain_bad_response",
                       "Сервис расчётов не вернул результат раскроя.")
    return {"project_id": project_id, "calc": calc,
            "state": _pipeline_state(result),
            "reference": (result.get("metrics") or {}).get("reference")}


@app.post("/projects/{project_id}/variants")
def run_variants(project_id: str = Path(...),
                 body: CalculationBody = CalculationBody(),
                 org_id: Optional[str] = Query(default=None),
                 authorization: Optional[str] = Header(default=None)) -> Dict[str, Any]:
    """`{layout_params, limit?}` → `{variants: [MaterialResult]}` (§12.6, F-11)."""
    cfg = get_config()
    _, membership = require_role(cfg, authorization, org_id, "member")
    result = _domain_calculate(membership, project_id, body, ["variants"],
                               name="Варианты раскроя")
    state = _pipeline_state(result)
    variants = state.get("variants") if isinstance(state, dict) else None
    if not isinstance(variants, list):
        variants = []
    return {"project_id": project_id, "variants": variants, "total": len(variants),
            "selected_variant_index": state.get("selectedVariantIndex", 0),
            "variants_limit": body.limit or 10}


@app.post("/projects/{project_id}/teo")
def run_teo(project_id: str = Path(...),
            body: CalculationBody = CalculationBody(),
            org_id: Optional[str] = Query(default=None),
            authorization: Optional[str] = Header(default=None)) -> Dict[str, Any]:
    """`{variant_id, teo_input}` → `{teo: TeoResult}` (§12.6, F-14)."""
    cfg = get_config()
    _, membership = require_role(cfg, authorization, org_id, "member")
    payload_body = body
    if body.teo_input is None:
        raise ApiError(422, "teo_input_required",
                       "Укажите teo_input (сортамент, машина, рабочее время).")
    if not body.teo_input.get("material_id") and not body.teo_input.get("material"):
        raise ApiError(422, "material_required",
                       "Укажите материал: material_id или material.")
    if not body.teo_input.get("machine_id") and not body.teo_input.get("machine"):
        raise ApiError(422, "machine_required",
                       "Укажите машину: machine_id или machine.")
    result = _domain_calculate(membership, project_id, payload_body, ["teo"],
                               name="ТЭО")
    stage = _stage_result(result, "teo") or {}
    teo = stage.get("teo") if isinstance(stage, dict) else None
    if not isinstance(teo, dict):
        raise ApiError(502, "domain_bad_response",
                       "Сервис расчётов не вернул результат ТЭО.")
    return {"project_id": project_id, "teo": teo,
            "comparison": stage.get("comparison"),
            "state": _pipeline_state(result)}


@app.post("/projects/{project_id}/teo/compare")
def run_teo_compare(project_id: str = Path(...),
                    body: CalculationBody = CalculationBody(),
                    org_id: Optional[str] = Query(default=None),
                    authorization: Optional[str] = Header(default=None)) -> Dict[str, Any]:
    """`{variant_ids, teo_input}` → `{comparison: …}` (§12.6, F-15)."""
    cfg = get_config()
    _, membership = require_role(cfg, authorization, org_id, "member")
    result = _domain_calculate(membership, project_id, body, ["teo"],
                               name="Сравнение вариантов")
    stage = _stage_result(result, "teo") or {}
    comparison = stage.get("comparison") if isinstance(stage, dict) else None
    if not isinstance(comparison, dict):
        raise ApiError(502, "domain_bad_response",
                       "Сервис расчётов не вернул сравнение вариантов.")
    return {"project_id": project_id, "comparison": comparison,
            "variants": stage.get("variants") or []}


# --------------------------------------------------------------------------
# Отчёты (§12.8) — генерация через domain-worker
# --------------------------------------------------------------------------

@app.get("/projects/{project_id}/reports")
def list_reports(project_id: str = Path(...),
                 org_id: Optional[str] = Query(default=None),
                 authorization: Optional[str] = Header(default=None)) -> Dict[str, Any]:
    cfg = get_config()
    _, membership = require_role(cfg, authorization, org_id, "viewer")
    _project_or_404(membership.org_id, project_id)
    rows = get_repo().list_reports(membership.org_id, project_id)
    return {"items": [repo_mod.report_json(r) for r in rows],
            "total": len(rows), "project_id": project_id}


@app.get("/reports/{report_id}")
def get_report(report_id: str = Path(...),
               authorization: Optional[str] = Header(default=None)) -> Dict[str, Any]:
    cfg = get_config()
    _, membership = require_role(cfg, authorization, None, "viewer")
    rep = get_repo().get_report(membership.org_id, report_id)
    if rep is None:
        raise ApiError(404, "report_not_found", "Отчёт не найден.")
    cfg = get_config()
    url = get_repo().presigned_url(rep["storage_key"], expires=cfg.presign_ttl,
                                   download_name=f"report.{rep['kind']}")
    return {"report": repo_mod.report_json(rep), "download_url": url}


@app.get("/reports/{report_id}/download")
def download_report(report_id: str = Path(...),
                    mode: str = Query(default="stream"),
                    authorization: Optional[str] = Header(default=None)) -> Response:
    cfg = get_config()
    _, membership = require_role(cfg, authorization, None, "viewer")
    rep = get_repo().get_report(membership.org_id, report_id)
    if rep is None:
        raise ApiError(404, "report_not_found", "Отчёт не найден.")
    if mode == "presigned":
        url = get_repo().presigned_url(rep["storage_key"], expires=cfg.presign_ttl,
                                       download_name=f"report.{rep['kind']}")
        return JSONResponse({"mode": "presigned", "url": url,
                             "expires_in": cfg.presign_ttl,
                             "report_id": report_id})
    if mode != "stream":
        raise ApiError(422, "invalid_mode", "Режим скачивания: stream или presigned.")
    body = get_repo().read_object(rep["storage_key"])
    mime = {"pdf": "application/pdf",
            "xlsx": "application/vnd.openxmlformats-officedocument."
                    "spreadsheetml.sheet",
            "dxf": "application/dxf"}.get(rep["kind"], "application/octet-stream")
    return Response(content=body, media_type=mime, headers={
        "Content-Length": str(len(body)),
        "Content-Disposition": f'attachment; filename="report.{rep["kind"]}"',
    })


# --------------------------------------------------------------------------
# Каталог цен организации (§12.7) — хранится в состоянии проекта-организации
# --------------------------------------------------------------------------

_CATALOG_KIND = "price_catalog"


@app.get("/orgs/{org_id}/catalog")
def get_catalog(org_id: str = Path(...),
                authorization: Optional[str] = Header(default=None)) -> Dict[str, Any]:
    cfg = get_config()
    _, membership = require_role(cfg, authorization, org_id, "viewer")
    repo = get_repo()
    rows = [p for p in repo.list_projects(membership.org_id)
            if p.get("name") == _CATALOG_KIND]
    catalog = repo_mod.parse_state(rows[0].get("state_json")).get("catalog") if rows else None
    return {"org_id": membership.org_id, "catalog": catalog}


@app.put("/orgs/{org_id}/catalog")
def put_catalog(body: CatalogBody, org_id: str = Path(...),
                authorization: Optional[str] = Header(default=None)) -> Dict[str, Any]:
    cfg = get_config()
    principal, membership = require_role(cfg, authorization, org_id, "member")
    repo = get_repo()
    rows = [p for p in repo.list_projects(membership.org_id)
            if p.get("name") == _CATALOG_KIND]
    state = {"catalog": body.catalog}
    if rows:
        repo.put_project_state(membership.org_id, rows[0]["id"], state)
    else:
        repo.create_project(membership.org_id, _CATALOG_KIND, principal.user_id,
                            state)
    return {"org_id": membership.org_id, "catalog": body.catalog}
