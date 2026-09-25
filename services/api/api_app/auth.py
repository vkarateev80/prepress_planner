# -*- coding: utf-8 -*-
"""Авторизация и тенант-изоляция сервиса `api` (N-4, System Design §3.4/§12.1).

Токены не разбираются локально: `api` (как и billing) спрашивает `auth` —
`POST /auth/verify` с тем же Bearer-токеном — и получает
`{sub, email, orgs:[{org_id, role}]}`. Дальше **каждая** выборка/запись в БД
фильтруется по `org_id` из этой выдачи (row-level изоляция) — чужой тенант
недоступен даже при знании идентификатора.

Внутренние вызовы идут через стандартную библиотеку (urllib), без внешних SDK.
Тесты подменяют `AuthVerifier` фейком (как в `services/payments/tests`).
"""
from __future__ import annotations

import json
import urllib.error
import urllib.request
from dataclasses import dataclass, field
from typing import Any, Dict, List, Optional

# Роли (System Design §12.2): owner/admin — управление, member — запись,
# viewer — только чтение.
ROLES = ("owner", "admin", "member", "viewer")
_RANK = {"viewer": 1, "member": 2, "admin": 3, "owner": 4}


class AuthError(Exception):
    """Ошибка авторизации: код HTTP + русское сообщение."""

    def __init__(self, status: int, message: str, code: str = "unauthorized") -> None:
        super().__init__(message)
        self.status = status
        self.message = message
        self.code = code


@dataclass
class Membership:
    org_id: str
    role: str = "member"

    def can(self, needed: str) -> bool:
        return _RANK.get(self.role, 0) >= _RANK.get(needed, 2)


@dataclass
class Principal:
    """Кто выполняет запрос: пользователь + его организации/роли."""

    user_id: str
    email: str = ""
    orgs: List[Membership] = field(default_factory=list)
    dev: bool = False

    def membership(self, org_id: Optional[str]) -> Membership:
        if not org_id:
            if not self.orgs:
                raise AuthError(
                    403, "У пользователя нет ни одной организации.", "no_org")
            return self.orgs[0]
        for m in self.orgs:
            if m.org_id == org_id:
                return m
        raise AuthError(
            403, "Нет доступа к организации: пользователь не состоит в ней.",
            "forbidden_org")

    def to_json(self) -> Dict[str, Any]:
        return {
            "user_id": self.user_id,
            "email": self.email,
            "orgs": [{"org_id": m.org_id, "role": m.role} for m in self.orgs],
            "dev": self.dev,
        }


def bearer_token(authorization: Optional[str]) -> str:
    if not authorization or not authorization.lower().startswith("bearer "):
        raise AuthError(401, "Требуется заголовок Authorization: Bearer <токен>.")
    token = authorization[7:].strip()
    if not token:
        raise AuthError(401, "Пустой токен доступа.")
    return token


class AuthVerifier:
    """Проверка токена через `auth POST /auth/verify` (внутренний вызов)."""

    def __init__(self, auth_url: str, timeout: float = 10.0) -> None:
        self.auth_url = (auth_url or "").rstrip("/")
        self.timeout = timeout

    def verify(self, token: str) -> Principal:
        if not self.auth_url:
            raise AuthError(503, "Сервис авторизации не настроен (PP_AUTH_URL).",
                            "auth_unconfigured")
        url = f"{self.auth_url}/auth/verify"
        req = urllib.request.Request(url, method="POST", data=b"", headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
        })
        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as resp:
                payload = json.loads(resp.read().decode("utf-8") or "{}")
        except urllib.error.HTTPError as exc:
            if exc.code in (401, 403):
                raise AuthError(
                    401, "Сессия недействительна или истекла — войдите заново.",
                    "invalid_token") from exc
            raise AuthError(
                503, f"Сервис авторизации недоступен (ошибка {exc.code}).",
                "auth_unavailable") from exc
        except (urllib.error.URLError, OSError) as exc:
            raise AuthError(
                503, f"Сервис авторизации недоступен: {exc}", "auth_unavailable"
            ) from exc
        except ValueError as exc:
            raise AuthError(
                502, "Сервис авторизации вернул некорректный ответ.",
                "auth_bad_response") from exc
        return self._principal(payload)

    @staticmethod
    def _principal(payload: Dict[str, Any]) -> Principal:
        sub = str(payload.get("sub") or payload.get("user_id") or "")
        if not sub:
            raise AuthError(401, "Сервис авторизации не вернул пользователя.",
                            "invalid_token")
        orgs: List[Membership] = []
        for item in payload.get("orgs") or []:
            if not isinstance(item, dict):
                continue
            org_id = item.get("org_id") or item.get("org")
            if not org_id:
                continue
            role = str(item.get("role") or "member").lower()
            orgs.append(Membership(str(org_id), role if role in ROLES else "member"))
        return Principal(user_id=sub, email=str(payload.get("email") or ""), orgs=orgs)


class DevVerifier:
    """Тестовый/локальный режим (PP_AUTH_REQUIRED=0): один синтетический тенант.

    ВНИМАНИЕ: включать только в dev — запросы без токена получают доступ к
    тенанту `PP_DEV_ORG_ID`. В проде `PP_AUTH_REQUIRED=1` (по умолчанию).
    """

    def __init__(self, org_id: str, user_id: str, role: str = "owner") -> None:
        self.org_id = org_id
        self.user_id = user_id
        self.role = role

    def verify(self, token: str) -> Principal:  # noqa: ARG002
        return Principal(
            user_id=self.user_id,
            email="dev@localhost",
            orgs=[Membership(self.org_id, self.role)],
            dev=True,
        )


def resolve_principal(config: Any, authorization: Optional[str]) -> Principal:
    """Определить пользователя: Bearer → auth/verify, либо dev-тенант."""
    verifier = getattr(config, "verifier", None)
    if verifier is None:
        if not config.auth_required:
            verifier = DevVerifier(config.dev_org_id, config.dev_user_id,
                                   config.dev_role)
        else:
            verifier = AuthVerifier(config.auth_url, config.http_timeout)
        config.verifier = verifier
    if isinstance(verifier, DevVerifier):
        return verifier.verify("")
    return verifier.verify(bearer_token(authorization))


def require_role(config: Any, authorization: Optional[str],
                 org_id: Optional[str], needed: str = "viewer"):
    """Проверить токен и членство в организации с нужным уровнем прав.

    Возвращает `(Principal, Membership)`; `org_id` из пути/запроса всегда
    сверяется с выданными auth организациями (N-4).
    """
    principal = resolve_principal(config, authorization)
    membership = principal.membership(org_id)
    if not membership.can(needed):
        raise AuthError(
            403,
            f"Недостаточно прав: требуется роль {needed} или выше "
            f"(у вас — {membership.role}).",
            "forbidden_role")
    return principal, membership
