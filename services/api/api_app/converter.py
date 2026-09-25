# -*- coding: utf-8 -*-
"""Клиент конвертера AI/CDR/EPS → SVG/PDF (ADR-7, F-2, F-4).

Конвертер — **отдельный сервис** (внутренний, порт 8120): браузер его не
вызывает; `api` обращается сервер-к-серверу по имени `converter` во внутренней
сети compose. Общий volume конвертера — «эстакада» (staging): результат
забирается и переносится в объектное хранилище под ключ проекта (ADR-5).

Контракт конвертера (без изменений, `services/converter`):
    POST /convert          multipart file + target=svg|pdf → {job_id}
    GET  /convert/{id}     → {status: pending|running|done|error, result_url, error}
    GET  {result_url}      статика /data/out/<job>/result.<ext>

Зависимостей нет: multipart собирается вручную, HTTP — через urllib.
Все ошибки — русские (F-4), исключение `ConverterError`.
"""
from __future__ import annotations

import json
import mimetypes
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from typing import Dict, Optional, Tuple

CLOSED_EXTENSIONS = (".ai", ".cdr", ".eps")
_EXT_BY_TARGET = {"svg": ".svg", "pdf": ".pdf"}


class ConverterError(RuntimeError):
    """Ошибка конвертации с русским сообщением (транслируется клиенту, F-4)."""


def is_closed_format(file_name: str) -> bool:
    """Требует ли файл серверной конвертации (AI/CDR/EPS, F-1/F-2)."""
    low = (file_name or "").lower()
    return low.endswith(CLOSED_EXTENSIONS)


def _ext(file_name: str) -> str:
    base = (file_name or "").rsplit("/", 1)[-1].rsplit("\\", 1)[-1]
    dot = base.rfind(".")
    return base[dot:].lower() if dot >= 0 else ""


class ConverterClient:
    """Серверный вызов конвертера (multipart → job → result → bytes)."""

    def __init__(self, base_url: str, timeout: float = 220.0,
                 poll_interval: float = 1.0) -> None:
        self.base_url = (base_url or "").rstrip("/")
        self.timeout = timeout
        self.poll_interval = max(0.05, poll_interval)

    # -- HTTP -------------------------------------------------------------
    def _post_multipart(self, path: str, file_name: str, data: bytes,
                        fields: Dict[str, str]) -> Tuple[int, bytes]:
        boundary = "----ppapi" + uuid.uuid4().hex
        ctype = mimetypes.guess_type(file_name)[0] or "application/octet-stream"
        chunks = []
        for key, value in fields.items():
            chunks.append(f"--{boundary}\r\n".encode("utf-8"))
            chunks.append(
                f'Content-Disposition: form-data; name="{key}"\r\n\r\n'
                f"{value}\r\n".encode("utf-8"))
        chunks.append(f"--{boundary}\r\n".encode("utf-8"))
        chunks.append(
            f'Content-Disposition: form-data; name="file"; '
            f'filename="{file_name}"\r\n'.encode("utf-8"))
        chunks.append(f"Content-Type: {ctype}\r\n\r\n".encode("utf-8"))
        chunks.append(data)
        chunks.append(f"\r\n--{boundary}--\r\n".encode("utf-8"))
        body = b"".join(chunks)

        req = urllib.request.Request(
            f"{self.base_url}{path}", data=body, method="POST",
            headers={
                "Content-Type": f"multipart/form-data; boundary={boundary}",
                "Content-Length": str(len(body)),
            })
        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as resp:
                return resp.status, resp.read()
        except urllib.error.HTTPError as exc:
            payload = b""
            try:
                payload = exc.read()
            except Exception:  # pragma: no cover
                pass
            raise ConverterError(self._detail(exc.code, payload)) from exc
        except urllib.error.URLError as exc:
            raise ConverterError(
                f"Сервис конвертации недоступен: {exc.reason}. "
                "Проверьте внутренний сервис converter (8120).") from exc

    @staticmethod
    def _detail(status: int, payload: bytes) -> str:
        text = payload.decode("utf-8", "replace").strip()
        try:
            data = json.loads(text)
            if isinstance(data, dict) and data.get("detail"):
                detail = data["detail"]
                if isinstance(detail, list) and detail:
                    first = detail[0]
                    if isinstance(first, dict) and first.get("msg"):
                        return str(first["msg"])
                return str(detail)
        except ValueError:
            pass
        return text or f"конвертер ответил ошибкой {status}"

    def _get_json(self, path: str) -> Dict[str, object]:
        req = urllib.request.Request(f"{self.base_url}{path}", method="GET")
        try:
            with urllib.request.urlopen(req, timeout=min(self.timeout, 30.0)) as resp:
                raw = resp.read().decode("utf-8", "replace")
        except urllib.error.HTTPError as exc:
            raise ConverterError(self._detail(exc.code, exc.read())) from exc
        except urllib.error.URLError as exc:
            raise ConverterError(
                f"Сервис конвертации недоступен: {exc.reason}.") from exc
        try:
            data = json.loads(raw)
        except ValueError as exc:
            raise ConverterError(
                "Конвертер вернул некорректный ответ.") from exc
        if not isinstance(data, dict):
            raise ConverterError("Конвертер вернул некорректный ответ.")
        return data

    # -- сценарий ---------------------------------------------------------
    def submit(self, file_name: str, data: bytes, target: str = "svg") -> str:
        if not is_closed_format(file_name):
            raise ConverterError(
                f"Формат «{_ext(file_name) or 'неизвестный'}» не конвертируется: "
                "допустимы AI, CDR, EPS.")
        if target not in ("svg", "pdf"):
            raise ConverterError("Целевой формат: svg или pdf.")
        status, payload = self._post_multipart(
            "/convert", "import" + _ext(file_name), data, {"target": target})
        try:
            parsed = json.loads(payload.decode("utf-8", "replace") or "{}")
        except ValueError:
            parsed = None
        if status == 200 and isinstance(parsed, dict) and parsed.get("job_id"):
            return str(parsed["job_id"])
        raise ConverterError(self._detail(status, payload))

    def wait(self, job_id: str, deadline: Optional[float] = None) -> str:
        """Дождаться готовности задачи и вернуть `result_url`."""
        limit = deadline if deadline is not None else time.monotonic() + self.timeout
        while True:
            data = self._get_json(f"/convert/{urllib.parse.quote(job_id)}")
            status = str(data.get("status") or "")
            if status == "done":
                url = data.get("result_url")
                if isinstance(url, str) and url:
                    return url
                raise ConverterError(
                    "Конвертер не вернул ссылку на результат конвертации.")
            if status == "error":
                err = data.get("error")
                raise ConverterError(
                    f"Конвертация не выполнена: {err}" if err
                    else "Конвертация не выполнена (ошибка на сервере).")
            if status not in ("pending", "running"):
                raise ConverterError(f"Неизвестный статус задачи: {status!r}.")
            if time.monotonic() > limit:
                raise ConverterError(
                    f"Конвертация не завершилась за {int(self.timeout)} с.")
            time.sleep(self.poll_interval)

    def fetch(self, result_url: str) -> bytes:
        url = result_url
        if not url.lower().startswith(("http://", "https://")):
            url = f"{self.base_url}/{url.lstrip('/')}"
        req = urllib.request.Request(url, method="GET")
        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as resp:
                return resp.read()
        except urllib.error.HTTPError as exc:
            raise ConverterError(
                f"Не удалось скачать результат конвертации "
                f"(ошибка {exc.code}).") from exc
        except urllib.error.URLError as exc:
            raise ConverterError(
                f"Результат конвертации недоступен: {exc.reason}.") from exc

    def convert(self, file_name: str, data: bytes,
                target: str = "svg") -> Tuple[bytes, str]:
        """Полный сценарий: загрузка → ожидание → скачивание результата.

        Возвращает `(bytes, mime)`; исключения — только `ConverterError`.
        """
        job_id = self.submit(file_name, data, target)
        result_url = self.wait(job_id)
        body = self.fetch(result_url)
        ext = _EXT_BY_TARGET.get(target, ".svg")
        mime = "image/svg+xml" if ext == ".svg" else "application/pdf"
        return body, mime
