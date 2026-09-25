# -*- coding: utf-8 -*-
"""S3-совместимое объектное хранилище (ADR-5) — только стандартная библиотека.

Гибрид по ADR-5: **blobs** лежат в объектном хранилище (dev/on-prem — MinIO,
prod — любой S3-совместимый сервис), **метаданные** — в PostgreSQL (§13.3 БД).
Публичный bucket запрещён: чтение — только через API (поток) либо по
короткоживущему **presigned GET** (SigV4, §4 System Design).

Ключ объекта (ADR-5):
    org/{org_id}/project/{project_id}/file/{file_id}/{version}/{sha256}/{name}

Реализация намеренно без `boto3`: SigV4-подпись собирается вручную
(hmac/hashlib/urllib) — зависимостей у сервиса ровно столько, сколько нужно
(uambiente может не иметь boto3; см. отчёт задачи).

Тесты используют `MemoryObjectStorage` (тот же интерфейс `ObjectStorage`).
"""
from __future__ import annotations

import hashlib
import hmac
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from typing import Any, Dict, Optional, Tuple
from urllib.parse import quote, urlsplit

EMPTY_SHA256 = hashlib.sha256(b"").hexdigest()
UNSIGNED_PAYLOAD = "UNSIGNED-PAYLOAD"


class StorageError(RuntimeError):
    """Ошибка объектного хранилища (сообщение — русское, для UI/логов)."""


def sha256_hex(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _sign(key: bytes, msg: str) -> bytes:
    return hmac.new(key, msg.encode("utf-8"), hashlib.sha256).digest()


def build_storage_key(prefix: str, org_id: str, project_id: str, file_id: str,
                      version: int, checksum: str, name: str) -> str:
    """Ключ объекта с префиксом организации (двойной рубеж изоляции, N-4)."""
    safe_name = urllib.parse.quote((name or "file").strip() or "file", safe="")
    return (
        f"{prefix}/{org_id}/project/{project_id}/file/{file_id}/{version}/"
        f"{checksum}/{safe_name}"
    )


class ObjectStorage:
    """Интерфейс объектного хранилища (S3-совместимый)."""

    name = "s3"

    def put(self, key: str, data: bytes, content_type: str = "application/octet-stream") -> None:
        raise NotImplementedError

    def get(self, key: str) -> bytes:
        raise NotImplementedError

    def exists(self, key: str) -> bool:
        raise NotImplementedError

    def delete(self, key: str) -> None:
        raise NotImplementedError

    def presigned_get_url(self, key: str, expires: int = 300,
                          download_name: Optional[str] = None) -> str:
        raise NotImplementedError


class S3ObjectStorage(ObjectStorage):
    """Клиент S3-совместимого хранилища (MinIO/AWS) с подписью SigV4."""

    name = "s3"

    def __init__(self, endpoint: str, bucket: str, access_key: str,
                 secret_key: str, region: str = "us-east-1",
                 public_endpoint: str = "", timeout: float = 30.0) -> None:
        if not endpoint:
            raise StorageError("OBJECT_STORAGE_ENDPOINT не задан")
        if not bucket:
            raise StorageError("OBJECT_STORAGE_BUCKET не задан")
        if not access_key or not secret_key:
            raise StorageError(
                "OBJECT_STORAGE_ACCESS_KEY/OBJECT_STORAGE_SECRET_KEY не заданы")
        self.endpoint = endpoint.rstrip("/")
        self.public_endpoint = (public_endpoint or endpoint).rstrip("/")
        self.bucket = bucket
        self.access_key = access_key
        self.secret_key = secret_key
        self.region = region or "us-east-1"
        self.timeout = timeout
        parts = urlsplit(self.endpoint)
        self.host = parts.netloc
        self.scheme = parts.scheme or "http"

    # -- SigV4 ------------------------------------------------------------
    @staticmethod
    def _amz_now() -> Tuple[str, str]:
        now = datetime.now(timezone.utc)
        return now.strftime("%Y%m%dT%H%M%SZ"), now.strftime("%Y%m%d")

    def _canonical_uri(self, key: str, bucket_scoped: bool = True) -> str:
        target = f"{self.bucket}/{key}" if bucket_scoped else self.bucket
        return "/" + quote(target, safe="/-_.~")

    def _signed_headers(self, method: str, key: str, query: Dict[str, str],
                        extra_headers: Dict[str, str], payload_hash: str,
                        amz_date: str, date_stamp: str,
                        bucket_scoped: bool = True) -> Dict[str, str]:
        headers = {
            "host": self.host,
            "x-amz-content-sha256": payload_hash,
            "x-amz-date": amz_date,
        }
        for k, v in (extra_headers or {}).items():
            headers[k.lower()] = v

        canonical_query = "&".join(
            f"{quote(k, safe='-_.~')}={quote(str(v), safe='-_.~')}"
            for k, v in sorted(query.items()))
        canonical_uri = self._canonical_uri(key, bucket_scoped)
        signed_names = ";".join(sorted(headers))
        canonical_headers = "".join(
            f"{k}:{' '.join(str(headers[k]).split())}\n" for k in sorted(headers))
        canonical_request = "\n".join([
            method, canonical_uri, canonical_query, canonical_headers,
            signed_names, payload_hash,
        ])
        scope = f"{date_stamp}/{self.region}/s3/aws4_request"
        string_to_sign = "\n".join([
            "AWS4-HMAC-SHA256", amz_date, scope,
            hashlib.sha256(canonical_request.encode("utf-8")).hexdigest(),
        ])
        k_date = _sign(("AWS4" + self.secret_key).encode("utf-8"), date_stamp)
        k_region = _sign(k_date, self.region)
        k_service = _sign(k_region, "s3")
        k_signing = _sign(k_service, "aws4_request")
        signature = hmac.new(
            k_signing, string_to_sign.encode("utf-8"), hashlib.sha256).hexdigest()
        auth = (
            f"AWS4-HMAC-SHA256 Credential={self.access_key}/{scope}, "
            f"SignedHeaders={signed_names}, Signature={signature}"
        )
        out = dict(extra_headers or {})
        out["x-amz-content-sha256"] = payload_hash
        out["x-amz-date"] = amz_date
        out["Authorization"] = auth
        return out

    def _request(self, method: str, key: str, *, query: Optional[Dict[str, str]] = None,
                 body: Optional[bytes] = None,
                 headers: Optional[Dict[str, str]] = None,
                 sign: bool = True,
                 endpoint: Optional[str] = None,
                 bucket_scoped: bool = True) -> Tuple[int, bytes]:
        query = query or {}
        base = (endpoint or self.endpoint).rstrip("/")
        uri = f"{base}{self._canonical_uri(key, bucket_scoped)}"
        if query:
            uri += "?" + urllib.parse.urlencode(
                {k: str(v) for k, v in sorted(query.items())})
        data = body if body is not None else None
        hdrs = dict(headers or {})
        if sign:
            amz_date, date_stamp = self._amz_now()
            payload_hash = (sha256_hex(data) if data is not None else EMPTY_SHA256)
            hdrs = self._signed_headers(method, key, query, hdrs, payload_hash,
                                        amz_date, date_stamp, bucket_scoped)
        req = urllib.request.Request(uri, data=data, headers=hdrs, method=method)
        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as resp:
                return resp.status, resp.read()
        except urllib.error.HTTPError as exc:
            detail = ""
            try:
                detail = exc.read().decode("utf-8", "replace")[:400]
            except Exception:  # pragma: no cover
                pass
            raise StorageError(
                f"Хранилище ответило ошибкой {exc.code} на {method} {key}: {detail}"
            ) from exc
        except urllib.error.URLError as exc:
            raise StorageError(
                f"Хранилище недоступно ({self.endpoint}): {exc.reason}") from exc

    # -- операции ---------------------------------------------------------
    def bucket_status(self) -> str:
        """`exists` | `created` | `error: …` — статус bucket для /healthz/старта."""
        try:
            if self._bucket_exists():
                return "exists"
            return self.ensure_bucket()
        except StorageError as exc:
            return f"error: {exc}"

    def _bucket_exists(self) -> bool:
        try:
            self._request("HEAD", "", bucket_scoped=False)
            return True
        except StorageError as exc:
            if "ошибкой 404" in str(exc):
                return False
            raise

    def ensure_bucket(self) -> str:
        """Создать bucket, если его нет (идемпотентно; dev/MinIO)."""
        body = b""
        if self.region != "us-east-1":
            body = (
                "<CreateBucketConfiguration "
                'xmlns="http://s3.amazonaws.com/doc/2006-03-01/">'
                f"<LocationConstraint>{self.region}</LocationConstraint>"
                "</CreateBucketConfiguration>"
            ).encode("utf-8")
        self._request("PUT", "", body=body, bucket_scoped=False,
                      headers={"Content-Type": "application/xml"})
        return "created"

    def put(self, key: str, data: bytes,
            content_type: str = "application/octet-stream") -> None:
        self._request("PUT", key, body=data, headers={
            "Content-Type": content_type or "application/octet-stream",
        })

    def get(self, key: str) -> bytes:
        _, body = self._request("GET", key)
        return body

    def exists(self, key: str) -> bool:
        try:
            self._request("HEAD", key)
            return True
        except StorageError:
            return False

    def delete(self, key: str) -> None:
        try:
            self._request("DELETE", key)
        except StorageError as exc:
            raise StorageError(f"Не удалось удалить объект {key}: {exc}") from exc

    def presigned_get_url(self, key: str, expires: int = 300,
                          download_name: Optional[str] = None) -> str:
        """Короткоживущая (по умолчанию 300 с) подписанная ссылка на чтение."""
        query = {
            "X-Amz-Algorithm": "AWS4-HMAC-SHA256",
            "X-Amz-Credential":
                f"{self.access_key}/{datetime.now(timezone.utc).strftime('%Y%m%d')}"
                f"/{self.region}/s3/aws4_request",
            "X-Amz-Date": "",
            "X-Amz-Expires": str(int(expires)),
            "X-Amz-SignedHeaders": "host",
        }
        amz_date, date_stamp = self._amz_now()
        query["X-Amz-Date"] = amz_date
        query["X-Amz-Credential"] = (
            f"{self.access_key}/{date_stamp}/{self.region}/s3/aws4_request")
        if download_name:
            query["response-content-disposition"] = (
                f'attachment; filename="{download_name}"')

        canonical_uri = self._canonical_uri(key, True)
        canonical_query = "&".join(
            f"{quote(k, safe='-_.~')}={quote(str(v), safe='-_.~')}"
            for k, v in sorted(query.items()))
        canonical_headers = f"host:{self.host}\n"
        canonical_request = "\n".join([
            "GET", canonical_uri, canonical_query, canonical_headers, "host",
            UNSIGNED_PAYLOAD,
        ])
        scope = f"{date_stamp}/{self.region}/s3/aws4_request"
        string_to_sign = "\n".join([
            "AWS4-HMAC-SHA256", amz_date, scope,
            hashlib.sha256(canonical_request.encode("utf-8")).hexdigest(),
        ])
        k_date = _sign(("AWS4" + self.secret_key).encode("utf-8"), date_stamp)
        k_region = _sign(k_date, self.region)
        k_service = _sign(k_region, "s3")
        k_signing = _sign(k_service, "aws4_request")
        signature = hmac.new(
            k_signing, string_to_sign.encode("utf-8"), hashlib.sha256).hexdigest()
        return (
            f"{self.public_endpoint}{canonical_uri}?{canonical_query}"
            f"&X-Amz-Signature={signature}"
        )


class MemoryObjectStorage(ObjectStorage):
    """In-memory хранилище для тестов (интерфейс тот же, что у S3)."""

    name = "memory"

    def __init__(self, base_url: str = "http://storage.test/prepress-saas") -> None:
        self.base_url = base_url.rstrip("/")
        self.objects: Dict[str, Tuple[bytes, str]] = {}

    def put(self, key: str, data: bytes,
            content_type: str = "application/octet-stream") -> None:
        self.objects[key] = (bytes(data), content_type or "application/octet-stream")

    def get(self, key: str) -> bytes:
        if key not in self.objects:
            raise StorageError(f"Объект не найден: {key}")
        return self.objects[key][0]

    def exists(self, key: str) -> bool:
        return key in self.objects

    def delete(self, key: str) -> None:
        self.objects.pop(key, None)

    def presigned_get_url(self, key: str, expires: int = 300,
                          download_name: Optional[str] = None) -> str:
        if key not in self.objects:
            raise StorageError(f"Объект не найден: {key}")
        return (f"{self.base_url}/{key}?X-Amz-Expires={int(expires)}"
                f"&X-Amz-Signature=test-signature")


def build_storage(config: Any) -> ObjectStorage:
    """Собрать хранилище по конфигурации (PP_STORAGE_BACKEND=s3|memory)."""
    if getattr(config, "storage_backend", "s3") == "memory":
        return MemoryObjectStorage()
    return S3ObjectStorage(
        endpoint=config.storage_endpoint,
        bucket=config.storage_bucket,
        access_key=config.storage_access_key,
        secret_key=config.storage_secret_key,
        region=config.storage_region,
        public_endpoint=config.storage_public_endpoint,
        timeout=config.http_timeout,
    )
