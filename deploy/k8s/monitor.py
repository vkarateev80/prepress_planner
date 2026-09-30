#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Мониторинг healthz сервисов «Препресс-Планер» + email-алерты.

Крон на сервере (см. deploy/k8s/README.md):
  */5 * * * * python3 /opt/pp/stack/deploy/k8s/monitor.py >> /var/log/pp-monitor.log 2>&1

Что проверяет (по одному HTTP с таймаутом):
  * edge      — https://<публичный origin>/healthz (PP_PUBLIC_BASE из cm)
  * api/auth/billing/converter/domain-worker/admin — http://<service>:<port>/healthz
  * minio     — http://minio:9000/minio/health/live
  * postgres  — pg_isready через kubectl exec
  * (nginx/k8s подами не проверяем — edge и есть его лицо)

Письмо отправляется ТОЛЬКО при изменении набора недоступных сервисов
(down→up / up→down); SMTP-креды читаются из ConfigMap pp-config —
в коде и git их нет. State-файл: /var/lib/pp-health/state.json.

 --dry-run: не шлёт письмо, печатает результат проверки.
"""
from __future__ import annotations

import json
import os
import smtplib
import ssl
import subprocess
import sys
import urllib.request
from datetime import datetime, timezone
from pathlib import Path
from typing import Dict, List, Tuple

NS = "prepress"
STATE_PATH = Path(os.environ.get("PP_HEALTH_STATE",
                                 "/var/lib/pp-health/state.json"))
DRY = "--dry-run" in sys.argv

# Скрипт крутится НА ХОСТЕ (нет кластерного DNS) — адреса берём из
# ClusterIP k8s Service: (имя проверки, имя Service, путь).
CHECKS: List[Tuple[str, str, str]] = [
    ("api", "api", "/healthz"),
    ("auth", "auth", "/healthz"),
    ("billing", "billing", "/healthz"),
    ("converter", "converter", "/healthz"),
    ("domain-worker", "domain-worker", "/healthz"),
    ("admin", "admin", "/healthz"),
    ("minio", "minio", "/minio/health/live"),
]


def _svc_urls() -> Dict[str, str]:
    """{имя сервиса: http://clusterIP:port} — один запрос kubectl."""
    raw = _kubectl("-n", NS, "get", "svc", "-o", "json")
    out: Dict[str, str] = {}
    for svc in json.loads(raw).get("items", []):
        name = svc["metadata"]["name"]
        ip = svc.get("spec", {}).get("clusterIP")
        ports = svc.get("spec", {}).get("ports") or []
        if ip and ip != "None" and ports:
            out[name] = f"http://{ip}:{ports[0].get('port')}"
    return out


def _kubectl(*args: str) -> str:
    out = subprocess.run(["kubectl", *args], capture_output=True,
                         text=True, timeout=30)
    if out.returncode != 0:
        raise RuntimeError(f"kubectl {' '.join(args)}: {out.stderr[:200]}")
    return out.stdout


def _probe(name: str, url: str) -> Tuple[str, bool, str]:
    try:
        with urllib.request.urlopen(url, timeout=4) as resp:
            ok = resp.status == 200
            return name, ok, str(resp.status)
    except Exception as exc:  # noqa: BLE001 — любой сбой = недоступен
        return name, False, str(exc)[:120]


def _pg_ok() -> Tuple[str, bool, str]:
    try:
        out = _kubectl("-n", NS, "exec", "deploy/postgresql", "--",
                       "pg_isready", "-U", "pp_user", "-d", "prepress_saas")
        ok = "accepting connections" in out
        return "postgresql", ok, out.strip()[:120]
    except Exception as exc:  # noqa: BLE001
        return "postgresql", False, str(exc)[:120]


def _edge_ok() -> Tuple[str, bool, str]:
    origin = ""
    try:
        cm = _kubectl("-n", NS, "get", "cm", "pp-config", "-o", "json")
        origin = json.loads(cm)["data"].get("PP_PUBLIC_BASE", "").rstrip("/")
    except Exception:  # noqa: BLE001 — без origin проверяем имя сервиса
        origin = ""
    url = f"{origin}/healthz" if origin else "http://web/healthz"
    return _probe("edge", url)


def _smtp_config() -> Dict[str, str]:
    cm = _kubectl("-n", NS, "get", "cm", "pp-config", "-o", "json")
    data = json.loads(cm)["data"]
    keys = ("PP_SMTP_HOST", "PP_SMTP_PORT", "PP_SMTP_USER",
            "PP_SMTP_PASSWORD", "PP_SMTP_FROM")
    return {k: data.get(k, "") for k in keys}


def _send_mail(subject: str, body: str) -> None:
    cfg = _smtp_config()
    if not cfg["PP_SMTP_HOST"]:
        print("SMTP не настроен в pp-config — письмо не отправлено")
        return
    port = int(cfg["PP_SMTP_PORT"] or "587")
    msg = f"From: {cfg['PP_SMTP_FROM']}\r\n" \
          f"To: {cfg['PP_SMTP_FROM']}\r\n" \
          f"Subject: {subject}\r\n" \
          f"Content-Type: text/plain; charset=utf-8\r\n\r\n{body}"
    with smtplib.SMTP(cfg["PP_SMTP_HOST"], port, timeout=20) as server:
        server.starttls(context=ssl.create_default_context())
        if cfg["PP_SMTP_USER"]:
            server.login(cfg["PP_SMTP_USER"], cfg["PP_SMTP_PASSWORD"])
        server.sendmail(cfg["PP_SMTP_FROM"], [cfg["PP_SMTP_FROM"]],
                        msg.encode("utf-8"))


def main() -> int:
    results: List[Tuple[str, bool, str]] = []
    try:
        results.append(_edge_ok())
    except Exception as exc:  # noqa: BLE001
        results.append(("edge", False, str(exc)[:120]))
    try:
        bases = _svc_urls()
    except Exception as exc:  # noqa: BLE001
        bases = {}
        results.append(("k8s-api", False, str(exc)[:120]))
    for name, svc, path in CHECKS:
        base = bases.get(svc)
        if not base:
            results.append((name, False, "Service не найден"))
            continue
        results.append(_probe(name, f"{base}{path}"))
    results.append(_pg_ok())

    down = sorted(name for name, ok, _ in results if not ok)
    stamp = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%SZ")
    lines = [f"{n}: {'OK' if ok else 'DOWN'} ({d})"
             for n, ok, d in results]
    print(f"[{stamp}] " + "; ".join(lines))

    prev = {}
    if STATE_PATH.exists():
        try:
            prev = json.loads(STATE_PATH.read_text())
        except (ValueError, OSError):
            prev = {}
    prev_down = sorted(prev.get("down", []))

    if down != prev_down:
        if down:
            subject = f"[Препресс-Планер] Недоступны: {', '.join(down)}"
            body = ("Проверка healthz не прошла:\n\n" + "\n".join(lines) +
                    f"\n\nВремя: {stamp}")
        else:
            subject = "[Препресс-Планер] Все сервисы восстановлены"
            body = ("Недоступных сервисов больше нет:\n\n" +
                    "\n".join(lines) + f"\n\nВремя: {stamp}")
        if DRY:
            print(f"DRY-RUN письмо: {subject}")
        else:
            try:
                _send_mail(subject, body)
                print(f"письмо отправлено: {subject}")
            except Exception as exc:  # noqa: BLE001
                print(f"ОШИБКА отправки письма: {exc}")
        STATE_PATH.parent.mkdir(parents=True, exist_ok=True)
        STATE_PATH.write_text(json.dumps(
            {"down": down, "updated": stamp}, ensure_ascii=False))
    else:
        # Изменений нет — state обновляем по времени, чтобы отразить проверку.
        STATE_PATH.parent.mkdir(parents=True, exist_ok=True)
        STATE_PATH.write_text(json.dumps(
            {"down": down, "updated": stamp}, ensure_ascii=False))

    # Код выхода: 0 — всё ок; 1 — есть down (для мониторинга крона).
    return 1 if down else 0


if __name__ == "__main__":
    sys.exit(main())
