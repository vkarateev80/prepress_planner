# -*- coding: utf-8 -*-
"""Проверка прав организации через billing (ADR-3, §12.3) — мягкий гейтинг.

`api` не хранит копию entitlement: источник истины — `billing`
(`GET /payments/entitlement`, где `features = {projects, teo, reports, …}`).
Поведение при недоступном billing — **fail-open** (доступ не блокируется):
недоступность соседнего сервиса не должна ломать уже оплаченный доступ,
а жёсткий отказ применяется только когда billing явно ответил «нельзя».

Free-тариф: `{projects: 1, teo: false, reports: false}`;
Pro: `{projects: null, teo: true, reports: true}` — `null` означает «без лимита».
"""
from __future__ import annotations

import json
import urllib.error
import urllib.parse
import urllib.request
from typing import Any, Dict, Optional


def fetch_entitlement(billing_url: str, token: str, org_id: str,
                      timeout: float = 8.0) -> Optional[Dict[str, Any]]:
    """Вернуть `{plan, status, pro, features}` или None (сервис недоступен)."""
    if not billing_url or not token:
        return None
    query = urllib.parse.urlencode({"org_id": org_id}) if org_id else ""
    url = f"{billing_url.rstrip('/')}/payments/entitlement"
    if query:
        url = f"{url}?{query}"
    req = urllib.request.Request(url, method="GET", headers={
        "Authorization": f"Bearer {token}",
        "Accept": "application/json",
    })
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            payload = json.loads(resp.read().decode("utf-8") or "{}")
    except (urllib.error.URLError, urllib.error.HTTPError, ValueError, OSError):
        return None
    return payload if isinstance(payload, dict) else None


def projects_limit(entitlement: Optional[Dict[str, Any]]) -> Optional[int]:
    """Лимит проектов: None — без лимита (Pro/неизвестно), int — жёсткий лимит."""
    if not entitlement:
        return None
    features = entitlement.get("features")
    if not isinstance(features, dict):
        return None
    if "projects" not in features:
        return None
    value = features.get("projects")
    if value is None:
        return None  # без лимита
    try:
        return int(value)
    except (TypeError, ValueError):
        return None
