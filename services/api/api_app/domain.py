# -*- coding: utf-8 -*-
"""Клиент `domain-worker` — канонического исполнителя домена (ADR-2, §3.3/§12.6).

`domain-worker` — серверный Dart-VM-сервис (внутренний, порт 8101): браузер его
не вызывает; `api` обращается **сервер-к-серверу** и остаётся единственным
владельцем оркестрации, персистентности и tenancy-изоляции (§3.4). Домен
(`packages/core`) api не исполняет и не дублирует.

Контракт воркера (см. `services/domain-worker/README.md`):
    GET  /healthz            → {status, service, version, availableStages…}
    POST /calculate          → state v2 (синонимы: /calculation, /run, /pipeline)

Тело запроса воркера — camelCase-схема `project_state.json v2`
(`app/lib/src/projects/project.dart`): `params` = `layoutParamsToJson`,
`teoInput`, `file_base64`/`file_path`, `stages`. Контракты §12.6 используют
snake_case (`layout_params`, `teo_input`, `file_version_id`) — перевод делает
этот модуль, чтобы wire-схема воркера осталась 1:1 с состоянием проекта.

Зависимостей нет: HTTP — через `urllib` (стандартная библиотека). Все ошибки —
русские, исключение `DomainError` (транслируется в конверт §12.1).
"""
from __future__ import annotations

import json
import urllib.error
import urllib.request
from typing import Any, Dict, Optional, Tuple

# Стадии домена (System Design §12.6, README воркера).
STAGES = ("parse", "analyze", "heal", "pattern", "calc", "variants", "teo")

# snake_case (§12.6) → camelCase воркера (`project_state.json v2`).
_PARAM_KEYS: Dict[str, str] = {
    "label_w": "labelW",
    "label_h": "labelH",
    "gap_x": "gapX",
    "gap_y": "gapY",
    "z_teeth": "zTeeth",
    "cp": "cp",
    "rapport_manual": "rapportManual",
    "cyl_width": "cylWidth",
    "web_width": "webWidth",
    "undercut": "undercut",
    "min_gap": "minGap",
    "mode": "mode",
    "count": "count",
    "length": "length",
}

# snake_case (§12.6) → camelCase воркера для входов ТЭО.
_TEO_KEYS: Dict[str, str] = {
    "material": "material",
    "machine": "machine",
    "work_time": "workTime",
    "tooling_cost": "toolingCost",
    "markup_pct": "markupPct",
    "setup_material_meters": "setupMaterialMeters",
    "shift_cost_per_shift": "shiftCostPerShift",
    "material_id": "materialId",
    "machine_id": "machineId",
    "hours_per_shift": "hoursPerShift",
    "shifts_per_day": "shiftsPerDay",
    "currency": "currency",
}


class DomainError(RuntimeError):
    """Ошибка доменного расчёта с русским сообщением (конверт §12.1)."""

    def __init__(self, message: str, *, status: int = 502,
                 code: str = "domain_error") -> None:
        super().__init__(message)
        self.message = message
        self.status = status
        self.code = code


def _camel(params: Dict[str, Any], mapping: Dict[str, str]) -> Dict[str, Any]:
    """Перевести ключи snake_case → camelCase воркера (уже camelCase — как есть)."""
    out: Dict[str, Any] = {}
    for key, value in (params or {}).items():
        camel = mapping.get(key)
        if camel is None and key in mapping.values():
            camel = key  # уже camelCase
        out[camel or key] = value
    return out


def normalize_layout_params(params: Optional[Dict[str, Any]]) -> Dict[str, Any]:
    """`layout_params` (§12.6, snake_case) → `params` воркера (camelCase)."""
    return _camel(params or {}, _PARAM_KEYS)


def normalize_teo_input(teo_input: Optional[Dict[str, Any]]) -> Dict[str, Any]:
    """`teo_input` (§12.6, snake_case) → `teoInput` воркера (camelCase)."""
    return _camel(teo_input or {}, _TEO_KEYS)


class DomainClient:
    """Серверный вызов `domain-worker` (`POST /calculate`)."""

    def __init__(self, base_url: str, timeout: float = 20.0) -> None:
        self.base_url = (base_url or "").rstrip("/")
        self.timeout = max(1.0, timeout)

    # -- HTTP -------------------------------------------------------------
    def _request(self, path: str, payload: Optional[Dict[str, Any]],
                 method: str = "POST") -> Dict[str, Any]:
        data = None
        headers = {"Accept": "application/json"}
        if payload is not None:
            data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
            headers["Content-Type"] = "application/json; charset=utf-8"
        req = urllib.request.Request(f"{self.base_url}{path}", data=data,
                                     method=method, headers=headers)
        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as resp:
                raw = resp.read().decode("utf-8", "replace")
        except urllib.error.HTTPError as exc:
            payload_bytes = b""
            try:
                payload_bytes = exc.read()
            except Exception:  # pragma: no cover
                pass
            raise self._error(exc.code, payload_bytes) from exc
        except urllib.error.URLError as exc:
            raise DomainError(
                f"Сервис расчётов (domain-worker) недоступен: {exc.reason}. "
                "Проверьте внутренний сервис domain-worker (8101).",
                status=503, code="domain_unavailable") from exc
        try:
            parsed = json.loads(raw or "{}")
        except ValueError as exc:
            raise DomainError(
                "Сервис расчётов вернул некорректный ответ (не JSON).",
                code="domain_bad_response") from exc
        if not isinstance(parsed, dict):
            raise DomainError(
                "Сервис расчётов вернул некорректный ответ.",
                code="domain_bad_response")
        return parsed

    @staticmethod
    def _error(status: int, payload: bytes) -> DomainError:
        """Разобрать русскую ошибку воркера `{"error":{code,message}}`."""
        text = payload.decode("utf-8", "replace").strip()
        code = "domain_error"
        message = ""
        try:
            data = json.loads(text)
        except ValueError:
            data = None
        if isinstance(data, dict):
            err = data.get("error")
            if isinstance(err, dict):
                code = str(err.get("code") or code)
                message = str(err.get("message") or "")
            elif data.get("detail"):
                detail = data["detail"]
                if isinstance(detail, list) and detail and isinstance(detail[0], dict):
                    message = str(detail[0].get("msg") or "")
                else:
                    message = str(detail)
        if not message:
            message = text or "Сервис расчётов ответил ошибкой."
        out_status = status if 400 <= status < 500 else 502
        if status == 422:
            code = "domain_bad_request"
        return DomainError(message, status=out_status, code=code)

    # -- сценарии ---------------------------------------------------------
    def healthz(self) -> Dict[str, Any]:
        return self._request("/healthz", None, method="GET")

    def calculate(self, payload: Dict[str, Any],
                  timeout: Optional[float] = None) -> Dict[str, Any]:
        """`POST /calculate` — доменная цепочка, ответ = state v2."""
        if timeout is not None:
            self.timeout = max(1.0, timeout)
        return self._request("/calculate", payload)

    # -- сборка запроса ---------------------------------------------------
    def build_payload(self, *, stages: Tuple[str, ...] = ("calc",),
                      name: str = "", params: Optional[Dict[str, Any]] = None,
                      teo_input: Optional[Dict[str, Any]] = None,
                      file_base64: Optional[str] = None,
                      file_name: str = "",
                      catalog: Optional[Dict[str, Any]] = None,
                      variants_limit: int = 10,
                      include_raw_paths: bool = False,
                      state: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
        """Собрать тело запроса воркера из контракта §12.6.

        `params` — уже `project_state.json v2` (camelCase) либо snake_case
        `layout_params`: оба варианта нормализуются.
        """
        payload: Dict[str, Any] = {
            "stages": list(stages),
            "name": name or "Расчёт",
            "params": normalize_layout_params(params),
            "variantsLimit": int(variants_limit),
            "includeRawPaths": bool(include_raw_paths),
            "includeErrors": True,
        }
        if teo_input:
            payload["teoInput"] = normalize_teo_input(teo_input)
        if catalog:
            payload["priceCatalog"] = catalog
        if file_base64:
            payload["file_base64"] = file_base64
            payload["fileName"] = file_name or ""
        if state:
            payload["state"] = state
        return payload
