# -*- coding: utf-8 -*-
"""Тесты сервиса `api`: проекты, файлы, изоляция тенантов, конвертер, S3-подпись.

Проверяется (System Design §12.4/§12.5/§13.3, ADR-5, ADR-7, N-4):
  * создание/список/детали проекта; ответ `{project_id, state}`;
  * обязательный Bearer-токен: без него — 401 (через `auth POST /auth/verify`);
  * **изоляция по организации (N-4)**: тенант A не видит проект/файл тенанта B
    (404/403), `storage_key` содержит `org_id`, список фильтруется по org;
  * загрузка файла: multipart ≤ PP_MAX_MB, sha256, ключ
    `org/{org}/project/{id}/file/{file}/{ver}/{sha}/{name}`, метаданные в БД;
  * валидация: неподдерживаемый формат → 422, превышение лимита → 413;
  * AI/CDR/EPS → вызов конвертера сервер-к-серверу (ADR-7) и перенос результата
    в объектное хранилище отдельным файлом `converter_result`;
  * скачивание: поток через API и presigned URL (mode=presigned);
  * мягкое удаление: `deleted_at`/`updated_at`, содержимое не теряется;
  * entitlement-гейтинг (Free: projects=1) при включённом PP_ENTITLEMENT_ENFORCE;
  * SigV4-подпись S3-ключей (Authorization/presigned), без boto3.

Внешние сервисы не вызываются: `auth` подменён фейком (как в
`services/payments/tests`), конвертер — `FakeConverter`, объектное хранилище —
`MemoryObjectStorage`. Сюита пригодна и для PostgreSQL: PP_TEST_DB_URL.
"""
import hashlib
import json
import os
import sys
import tempfile
from pathlib import Path
from typing import Any, Dict, List, Optional

import pytest

os.environ.pop("DB_URL", None)
if os.environ.get("PP_TEST_DB_URL"):
    os.environ["DB_URL"] = os.environ["PP_TEST_DB_URL"]

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from fastapi.testclient import TestClient  # noqa: E402

from api_app import main as api_main  # noqa: E402
from api_app import repo as repo_mod  # noqa: E402
from api_app.auth import AuthError, Membership, Principal  # noqa: E402
from api_app.config import Config  # noqa: E402
from api_app.storage import (MemoryObjectStorage, S3ObjectStorage,  # noqa: E402
                             build_storage_key)

TENANT_A = "orgA0000000000001"
TENANT_B = "orgB0000000000002"
TOKEN_A = "token-tenant-a"
TOKEN_B = "token-tenant-b"
ADMIN_A = "token-admin-a"

# --- фейковые внешние сервисы ---------------------------------------------

class FakeVerifier:
    """Замена `auth POST /auth/verify` (формат ответа — как у auth)."""

    def __init__(self, tokens: Dict[str, Principal]) -> None:
        self.tokens = tokens

    def verify(self, token: str) -> Principal:
        principal = self.tokens.get(token)
        if principal is None:
            raise AuthError(401, "Сессия недействительна или истекла — войдите заново.",
                            "invalid_token")
        return principal


class FakeConverter:
    """Замена сервиса converter (8120): AI/CDR/EPS → SVG без Inkscape."""

    def __init__(self) -> None:
        self.calls: List[Dict[str, Any]] = []

    def convert(self, file_name: str, data: bytes, target: str = "svg"):
        self.calls.append({"name": file_name, "size": len(data), "target": target})
        svg = (b'<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10">'
               b'<path d="M0 0 L10 0 L10 10 Z"/></svg>')
        return svg, "image/svg+xml"


def _principal(orgs, user_id="user-1", email="user@example.com") -> Principal:
    return Principal(user_id=user_id, email=email,
                     orgs=[Membership(o, r) for o, r in orgs])


@pytest.fixture()
def env(monkeypatch):
    """Свежий рантайм на временной БД + memory-хранилище + фейки."""
    tmp = tempfile.mkdtemp(prefix="pp_api_test_")
    cfg = Config({
        "PP_DATA_DIR": tmp,
        "PP_AUTH_URL": "http://auth.test:8121",
        "PP_BILLING_URL": "http://billing.test:8122",
        "CONVERTER_URL": "http://converter.test:8120",
        "OBJECT_STORAGE_ENDPOINT": "http://minio.test:9000",
        "OBJECT_STORAGE_BUCKET": "prepress-saas",
        "OBJECT_STORAGE_ACCESS_KEY": "test-key",
        "OBJECT_STORAGE_SECRET_KEY": "test-secret",
        "PP_STORAGE_BACKEND": "memory",
        "PP_MAX_MB": "50",
        "PP_AUTH_REQUIRED": "1",
        "PP_ENTITLEMENT_ENFORCE": "0",
        "PP_PRESIGN_TTL": "300",
    })
    cfg.verifier = FakeVerifier({
        TOKEN_A: _principal([(TENANT_A, "owner")], "user-a", "a@example.com"),
        ADMIN_A: _principal([(TENANT_A, "admin")], "user-admin", "admin@example.com"),
        TOKEN_B: _principal([(TENANT_B, "owner")], "user-b", "b@example.com"),
    })
    runtime = api_main.build_runtime(cfg)
    runtime["storage"] = MemoryObjectStorage()
    runtime["repo"] = repo_mod.Repo(runtime["db"], runtime["storage"],
                                    key_prefix="org", max_versions=3)
    runtime["converter"] = FakeConverter()
    runtime["storage_status"] = "memory"
    api_main.STATE.update(runtime)
    api_main.STATE["jobs"].clear()
    client = TestClient(api_main.app)
    yield client
    api_main.STATE.update({"config": None, "db": None, "storage": None,
                           "repo": None, "converter": None})


def _headers(token: str) -> Dict[str, str]:
    return {"Authorization": f"Bearer {token}"}


def _create_project(client: TestClient, token: str = TOKEN_A,
                    name: str = "Проект A") -> Dict[str, Any]:
    resp = client.post("/api/projects", json={"name": name}, headers=_headers(token))
    assert resp.status_code == 201, resp.text
    return resp.json()


def _upload(client: TestClient, project_id: str, name: str = "label.svg",
            data: bytes = b"<svg/>", token: str = TOKEN_A,
            extra: Optional[Dict[str, str]] = None):
    files = {"file": (name, data, "application/octet-stream")}
    form = dict(extra or {})
    return client.post(f"/api/projects/{project_id}/files", files=files, data=form,
                       headers=_headers(token))


# --- health / авторизация --------------------------------------------------

def test_healthz_reports_configuration(env):
    body = env.get("/healthz").json()
    assert body["status"] == "ok"
    assert body["service"] == "api"
    assert body["db_kind"] == (
        "postgresql" if os.environ.get("PP_TEST_DB_URL") else "sqlite")
    assert body["storage"] == "memory"
    assert body["max_mb"] == 50.0
    assert "storage_key" not in body  # секретов/ключей в healthz нет
    assert "projects" in body["tables"] and "file_versions" in body["tables"]


def test_unauthorized_without_token(env):
    assert env.get("/api/projects").status_code == 401
    assert env.post("/api/projects", json={"name": "X"}).status_code == 401


def test_invalid_token_rejected(env):
    resp = env.get("/api/projects", headers=_headers("unknown-token"))
    assert resp.status_code == 401
    assert resp.json()["error"]["code"] == "invalid_token"
    assert "недействительна" in resp.json()["error"]["message"]


def test_role_required_for_delete(env):
    project = _create_project(env)
    # У member нет прав на удаление проекта (нужна роль admin+).
    cfg = api_main.get_config()
    cfg.verifier.tokens["token-member-a"] = _principal([(TENANT_A, "member")],
                                                      "user-m")
    resp = env.delete(f"/api/projects/{project['project_id']}",
                      headers=_headers("token-member-a"))
    assert resp.status_code == 403
    assert resp.json()["error"]["code"] == "forbidden_role"


# --- проекты ---------------------------------------------------------------

def test_create_project_returns_id_and_state(env):
    project = _create_project(env, name="  Этикетка 50x30  ")
    assert project["project_id"].startswith("prj_")
    assert project["state"] == {}
    assert project["org_id"] == TENANT_A
    assert project["project"]["name"] == "Этикетка 50x30"
    assert project["project"]["created_by"] == "user-a"


def test_create_project_validates_name(env):
    resp = env.post("/api/projects", json={"name": "   "}, headers=_headers(TOKEN_A))
    assert resp.status_code == 422
    assert resp.json()["error"]["code"] == "invalid_name"


def test_create_project_duplicate_name_blocked(env):
    """Одноимённый проект в организации не создаётся (409)."""
    _create_project(env, name="Этикетка")
    resp = env.post("/api/projects", json={"name": "  Этикетка  "},
                    headers=_headers(TOKEN_A))
    assert resp.status_code == 409
    assert resp.json()["error"]["code"] == "project_exists"
    assert "уже существует" in resp.json()["error"]["message"]
    # В организации по-прежнему один проект с этим именем.
    items = env.get("/api/projects", headers=_headers(TOKEN_A)).json()["items"]
    assert [p["name"] for p in items] == ["Этикетка"]
    # Другая организация с тем же именем — нормально.
    _create_project(env, TOKEN_B, "Этикетка")
    # После мягкого удаления имя снова свободно.
    pid = env.get("/api/projects", headers=_headers(TOKEN_A)).json()["items"][0]
    assert env.delete(f"/api/projects/{pid['id']}",
                      headers=_headers(TOKEN_A)).status_code == 204
    _create_project(env, name="Этикетка")


def test_rename_project_to_existing_name_blocked(env):
    """Переименование на занятое имя — 409; своё/без изменений — ок."""
    first = _create_project(env, name="Первый")
    second = _create_project(env, name="Второй")
    resp = env.patch(f"/api/projects/{second['project_id']}",
                     json={"name": "Первый"}, headers=_headers(TOKEN_A))
    assert resp.status_code == 409
    assert resp.json()["error"]["code"] == "project_exists"
    # Переименование в собственное текущее имя — не блокируется.
    resp = env.patch(f"/api/projects/{first['project_id']}",
                     json={"name": "Первый"}, headers=_headers(TOKEN_A))
    assert resp.status_code == 200
    # Свободное имя — переименование проходит.
    resp = env.patch(f"/api/projects/{second['project_id']}",
                     json={"name": "Третий"}, headers=_headers(TOKEN_A))
    assert resp.status_code == 200
    assert resp.json()["project"]["name"] == "Третий"


def test_list_projects_is_isolated_by_org(env):
    _create_project(env, TOKEN_A, "Проект A")
    _create_project(env, TOKEN_B, "Проект B")
    list_a = env.get("/api/projects", headers=_headers(TOKEN_A)).json()
    list_b = env.get("/api/projects", headers=_headers(TOKEN_B)).json()
    assert [p["name"] for p in list_a["items"]] == ["Проект A"]
    assert [p["name"] for p in list_b["items"]] == ["Проект B"]
    assert list_a["org_id"] == TENANT_A


def test_tenant_a_cannot_read_tenant_b_project(env):
    project_b = _create_project(env, TOKEN_B, "Секрет B")
    resp = env.get(f"/api/projects/{project_b['project_id']}",
                   headers=_headers(TOKEN_A))
    assert resp.status_code == 404
    assert resp.json()["error"]["code"] == "project_not_found"


def test_org_id_query_cannot_be_spoofed(env):
    """Членство проверяется по выдаче auth, а не по параметру запроса."""
    resp = env.get(f"/api/projects?org_id={TENANT_B}", headers=_headers(TOKEN_A))
    assert resp.status_code == 403
    assert resp.json()["error"]["code"] == "forbidden_org"


def test_project_details_include_files_and_versions(env):
    project = _create_project(env)
    _upload(env, project["project_id"], "label.svg", b"<svg>1</svg>")
    body = env.get(f"/api/projects/{project['project_id']}",
                   headers=_headers(TOKEN_A)).json()
    assert body["project"]["id"] == project["project_id"]
    assert len(body["files"]) == 1
    assert len(body["versions"]) == 1
    assert body["versions"][0]["version"] == 1
    assert body["versions"][0]["kind"] == "original"


def test_v1_prefix_is_supported(env):
    """§12.4 задаёт `/api/v1/projects` — путь нормализуется middleware."""
    resp = env.post("/api/v1/projects", json={"name": "Через v1"},
                    headers=_headers(TOKEN_A))
    assert resp.status_code == 201
    assert resp.json()["project"]["name"] == "Через v1"


def test_project_state_can_be_updated(env):
    project = _create_project(env)
    state = {"schemaVersion": 2, "name": "Проект A",
             "calc": {"wastePct": 26.18, "perLabelArea": 2032.0}}
    resp = env.patch(f"/api/projects/{project['project_id']}", json={"state": state},
                     headers=_headers(TOKEN_A))
    assert resp.status_code == 200
    assert resp.json()["project"]["state"]["calc"]["wastePct"] == 26.18


# --- файлы -----------------------------------------------------------------

def test_upload_file_stores_blob_and_metadata(env):
    project = _create_project(env)
    data = b"<svg>label</svg>"
    resp = _upload(env, project["project_id"], "label.svg", data)
    assert resp.status_code == 201, resp.text
    body = resp.json()
    expected_sha = hashlib.sha256(data).hexdigest()
    assert body["file_id"].startswith("file_")
    assert body["checksum"] == expected_sha
    assert body["version"] == 1
    assert body["storage_key"] == (
        f"org/{TENANT_A}/project/{project['project_id']}/file/"
        f"{body['file_id']}/1/{expected_sha}/label.svg")
    assert body["file"]["size_bytes"] == len(data)
    assert body["file"]["file_type"] == "original"
    assert body["file"]["source_kind"] == "uploaded"
    assert body["org_id"] == TENANT_A
    # blob действительно в объектном хранилище
    assert api_main.STATE["storage"].get(body["storage_key"]) == data


def test_upload_rejects_unsupported_format(env):
    project = _create_project(env)
    resp = _upload(env, project["project_id"], "virus.exe", b"MZ")
    assert resp.status_code == 422
    assert resp.json()["error"]["code"] == "unsupported_format"
    assert "не поддерживается" in resp.json()["error"]["message"]


def test_upload_rejects_oversize_file(env):
    project = _create_project(env)
    cfg = api_main.get_config()
    cfg.max_upload_bytes = 1024  # 1 КБ для теста
    resp = _upload(env, project["project_id"], "big.svg", b"x" * 4096)
    assert resp.status_code == 413
    assert resp.json()["error"]["code"] == "file_too_large"
    assert "1 МБ" in resp.json()["error"]["message"] or "МБ" in resp.json()["error"]["message"]


def test_upload_rejects_content_type_mismatch(env):
    project = _create_project(env)
    resp = env.post(
        f"/api/projects/{project['project_id']}/files",
        files={"file": ("label.svg", b"<svg/>", "text/html")},
        headers=_headers(TOKEN_A))
    assert resp.status_code == 422
    assert resp.json()["error"]["code"] == "content_type_mismatch"


def test_upload_rejects_empty_file(env):
    project = _create_project(env)
    resp = _upload(env, project["project_id"], "empty.svg", b"")
    assert resp.status_code == 422
    assert resp.json()["error"]["code"] == "empty_file"


def test_file_metadata_endpoints(env):
    project = _create_project(env)
    file_id = _upload(env, project["project_id"]).json()["file_id"]
    meta = env.get(f"/api/files/{file_id}", headers=_headers(TOKEN_A)).json()
    assert meta["file"]["id"] == file_id
    assert "content" not in meta
    nested = env.get(f"/api/projects/{project['project_id']}/files/{file_id}",
                     headers=_headers(TOKEN_A)).json()
    assert nested["file"]["id"] == file_id
    listing = env.get(f"/api/projects/{project['project_id']}/files",
                      headers=_headers(TOKEN_A)).json()
    assert listing["total"] == 1


def test_file_isolation_by_org(env):
    project_a = _create_project(env, TOKEN_A)
    file_id = _upload(env, project_a["project_id"]).json()["file_id"]
    # Тенант B не видит ни метаданные, ни скачивание файла тенанта A.
    assert env.get(f"/api/files/{file_id}",
                   headers=_headers(TOKEN_B)).status_code == 404
    assert env.get(f"/api/files/{file_id}/download",
                   headers=_headers(TOKEN_B)).status_code == 404
    # И не может загрузить файл в чужой проект.
    resp = _upload(env, project_a["project_id"], token=TOKEN_B)
    assert resp.status_code == 404


def test_download_stream_and_presigned(env):
    project = _create_project(env)
    data = b"<svg>download</svg>"
    file_id = _upload(env, project["project_id"], "label.svg", data).json()["file_id"]

    stream = env.get(f"/api/files/{file_id}/download", headers=_headers(TOKEN_A))
    assert stream.status_code == 200
    assert stream.content == data
    assert stream.headers["x-pp-checksum-sha256"] == hashlib.sha256(data).hexdigest()

    pres = env.get(f"/api/files/{file_id}/download?mode=presigned",
                   headers=_headers(TOKEN_A))
    assert pres.status_code == 200
    body = pres.json()
    assert body["mode"] == "presigned"
    assert body["expires_in"] == 300
    assert body["url"].startswith("http://storage.test/")


def test_download_rejects_bad_mode(env):
    project = _create_project(env)
    file_id = _upload(env, project["project_id"]).json()["file_id"]
    resp = env.get(f"/api/files/{file_id}/download?mode=teleport",
                   headers=_headers(TOKEN_A))
    assert resp.status_code == 422
    assert resp.json()["error"]["code"] == "invalid_mode"


def test_soft_delete_file_and_project(env):
    project = _create_project(env)
    file_id = _upload(env, project["project_id"]).json()["file_id"]

    assert env.delete(f"/api/files/{file_id}",
                      headers=_headers(TOKEN_A)).status_code == 204
    assert env.get(f"/api/files/{file_id}", headers=_headers(TOKEN_A)).status_code == 404
    row = api_main.get_repo().get_file(TENANT_A, file_id, include_deleted=True)
    assert row["deleted_at"] and row["updated_at"] >= row["deleted_at"]
    # blob не удаляется — soft delete не разрушает данные
    assert api_main.STATE["storage"].exists(row["storage_key"])

    assert env.delete(f"/api/projects/{project['project_id']}",
                      headers=_headers(TOKEN_A)).status_code == 204
    assert env.get(f"/api/projects/{project['project_id']}",
                   headers=_headers(TOKEN_A)).status_code == 404
    assert env.get("/api/projects", headers=_headers(TOKEN_A)).json()["total"] == 0


def test_versions_are_pruned_by_limit(env):
    """PP_MAX_FILE_VERSIONS=3 в тестовом рантайме: старые версии — в deleted_at."""
    project = _create_project(env)
    file_id = _upload(env, project["project_id"], "label.svg", b"<svg>1</svg>").json()["file_id"]
    repo = api_main.get_repo()
    for i in range(2, 6):
        repo.add_version(TENANT_A, file_id, f"<svg>{i}</svg>".encode(),
                         mime="image/svg+xml", kind="healed")
    versions = repo.list_versions(TENANT_A, file_id)
    assert [v["version"] for v in versions] == [3, 4, 5]
    assert repo.get_file(TENANT_A, file_id)["version"] == 5


# --- конвертер (ADR-7) -----------------------------------------------------

def test_closed_format_triggers_converter_and_stores_result(env):
    project = _create_project(env)
    resp = _upload(env, project["project_id"], "artwork.ai", b"%PDF-1.4 fake ai",
                   extra={"convert": "svg"})
    assert resp.status_code == 201, resp.text
    body = resp.json()
    assert body["converted"] is True
    assert body["converter_status"] == "done"
    assert body["converted_file_id"].startswith("file_")
    assert body["converted_file"]["file_type"] == "converter_result"
    assert body["converted_file"]["source_kind"] == "converted"
    assert body["converted_file"]["parent_file_id"] == body["file_id"]
    assert body["converted_file"]["name"] == "artwork.svg"
    assert body["converted_file"]["mime"] == "image/svg+xml"
    key = body["converted_storage_key"]
    assert key.startswith(f"org/{TENANT_A}/project/{project['project_id']}/file/")
    assert api_main.STATE["storage"].exists(key)
    # Оригинал сохранён (аудит) и результат конвертации — отдельный файл.
    files = env.get(f"/api/projects/{project['project_id']}/files",
                    headers=_headers(TOKEN_A)).json()["items"]
    assert sorted(f["file_type"] for f in files) == ["converter_result", "original"]
    assert api_main.STATE["converter"].calls[0]["name"] == "artwork.ai"


def test_convert_endpoint_async_job(env):
    project = _create_project(env)
    file_id = _upload(env, project["project_id"], "artwork.eps",
                      b"%!PS-Adobe fake eps").json()["file_id"]
    resp = env.post(
        f"/api/projects/{project['project_id']}/files/{file_id}/convert?target=svg",
        headers=_headers(TOKEN_A))
    assert resp.status_code == 202, resp.text
    job = resp.json()
    assert job["job_id"].startswith("job_")

    status = env.get(job["job_status_url"], headers=_headers(TOKEN_A)).json()
    assert status["status"] in ("pending", "running", "done")
    # дожидаемся завершения потока
    for _ in range(200):
        status = env.get(f"/api/jobs/{job['job_id']}",
                         headers=_headers(TOKEN_A)).json()
        if status["status"] in ("done", "error"):
            break
    assert status["status"] == "done", status
    assert status["result"]["converted_file"]["file_type"] == "converter_result"


def test_job_is_isolated_by_org(env):
    project = _create_project(env)
    file_id = _upload(env, project["project_id"], "artwork.eps",
                      b"%!PS fake").json()["file_id"]
    job_id = env.post(
        f"/api/projects/{project['project_id']}/files/{file_id}/convert",
        headers=_headers(TOKEN_A)).json()["job_id"]
    assert env.get(f"/api/jobs/{job_id}", headers=_headers(TOKEN_B)).status_code == 404


def test_convert_only_closed_formats(env):
    project = _create_project(env)
    file_id = _upload(env, project["project_id"], "label.svg", b"<svg/>").json()["file_id"]
    resp = env.post(
        f"/api/projects/{project['project_id']}/files/{file_id}/convert",
        headers=_headers(TOKEN_A))
    assert resp.status_code == 422
    assert resp.json()["error"]["code"] == "not_convertible"


# --- entitlement -----------------------------------------------------------

def test_free_plan_project_limit(env, monkeypatch):
    cfg = api_main.get_config()
    cfg.entitlement_enforce = True
    monkeypatch.setattr(api_main, "fetch_entitlement",
                        lambda *a, **kw: {"plan": "free", "pro": False,
                                          "features": {"projects": 1}})
    _create_project(env, TOKEN_A, "Первый")
    resp = env.post("/api/projects", json={"name": "Второй"},
                    headers=_headers(TOKEN_A))
    assert resp.status_code == 403
    assert resp.json()["error"]["code"] == "plan_limit"
    assert resp.json()["error"]["details"]["limit"] == 1


def test_entitlement_fail_open_when_billing_down(env, monkeypatch):
    cfg = api_main.get_config()
    cfg.entitlement_enforce = True
    monkeypatch.setattr(api_main, "fetch_entitlement", lambda *a, **kw: None)
    assert _create_project(env, TOKEN_A, "Без billing")["project_id"]


def test_pro_plan_has_no_limit(env, monkeypatch):
    cfg = api_main.get_config()
    cfg.entitlement_enforce = True
    monkeypatch.setattr(api_main, "fetch_entitlement",
                        lambda *a, **kw: {"plan": "pro", "pro": True,
                                          "features": {"projects": None}})
    for i in range(3):
        assert _create_project(env, TOKEN_A, f"Проект {i}")["project_id"]


# --- S3 (SigV4) ------------------------------------------------------------

def test_storage_key_layout():
    key = build_storage_key("org", TENANT_A, "prj1", "file1", 2, "abc", "макет 1.svg")
    assert key.startswith(f"org/{TENANT_A}/project/prj1/file/file1/2/abc/")
    assert key.endswith("1.svg")  # имя URL-кодируется, но читаемо


def test_s3_sigv4_put_and_presign(monkeypatch):
    s3 = S3ObjectStorage("http://minio:9000", "prepress-saas", "key", "secret")
    captured: Dict[str, Any] = {}

    def fake_urlopen(req, timeout=None):  # noqa: ARG001
        captured["method"] = req.method
        captured["url"] = req.full_url
        captured["headers"] = {k.lower(): v for k, v in req.headers.items()}
        captured["data"] = req.data

        class _Resp:
            status = 200

            def read(self) -> bytes:
                return b""

            def __enter__(self):
                return self

            def __exit__(self, *a) -> bool:
                return False

        return _Resp()

    import api_app.storage as storage_mod
    monkeypatch.setattr(storage_mod.urllib.request, "urlopen", fake_urlopen)
    s3.put("org/A/project/P/file/F/1/sha/label.svg", b"<svg/>", "image/svg+xml")
    headers = captured["headers"]
    assert headers["authorization"].startswith("AWS4-HMAC-SHA256 Credential=key/")
    signed = headers["authorization"].split("SignedHeaders=")[1].split(",")[0]
    assert signed == "content-type;host;x-amz-content-sha256;x-amz-date"
    assert headers["x-amz-content-sha256"] == hashlib.sha256(b"<svg/>").hexdigest()
    assert captured["url"] == (
        "http://minio:9000/prepress-saas/org/A/project/P/file/F/1/sha/label.svg")
    url = s3.presigned_get_url("org/A/project/P/file/F/1/sha/label.svg",
                               expires=120, download_name="label.svg")
    assert "X-Amz-Algorithm=AWS4-HMAC-SHA256" in url
    assert "X-Amz-Expires=120" in url
    assert "X-Amz-Signature=" in url
    assert url.startswith("http://minio:9000/prepress-saas/org/A/")


def test_memory_storage_matches_interface():
    store = MemoryObjectStorage()
    store.put("k", b"1")
    assert store.exists("k") and store.get("k") == b"1"
    assert "X-Amz-Signature" in store.presigned_get_url("k")
    store.delete("k")
    assert not store.exists("k")


def test_schema_init_is_idempotent(env):
    """Повторный init_schema (рестарт сервиса) не ломает данные."""
    project = _create_project(env)
    db = api_main.STATE["db"]
    db.init_schema()
    db.init_schema()
    assert env.get(f"/api/projects/{project['project_id']}",
                   headers=_headers(TOKEN_A)).status_code == 200


def test_s3_bucket_bootstrap_creates_missing_bucket(monkeypatch):
    """api создаёт bucket при старте, если его нет (MinIO/dev)."""
    import api_app.storage as storage_mod

    s3 = S3ObjectStorage("http://minio:9000", "prepress-saas", "key", "secret")
    calls: List[str] = []

    def fake_urlopen(req, timeout=None):  # noqa: ARG001
        calls.append(req.method)
        if req.method == "HEAD":
            raise storage_mod.urllib.error.HTTPError(
                req.full_url, 404, "Not Found", {}, None)  # type: ignore[arg-type]

        class _Resp:
            status = 200

            def read(self) -> bytes:
                return b""

            def __enter__(self):
                return self

            def __exit__(self, *a) -> bool:
                return False

        return _Resp()

    monkeypatch.setattr(storage_mod.urllib.request, "urlopen", fake_urlopen)
    assert s3.bucket_status() == "created"
    assert calls == ["HEAD", "PUT"]
