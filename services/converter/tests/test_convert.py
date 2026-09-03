# -*- coding: utf-8 -*-
"""Тесты сервиса конвертации."""
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]  # services/converter
sys.path.insert(0, str(ROOT))

from fastapi.testclient import TestClient  # noqa: E402

from converter_app.main import app  # noqa: E402
from converter_app.convert import gs_available, inkscape_available  # noqa: E402

FIXTURES = ROOT.parents[1] / "fixtures"  # vibe cam/fixtures
client = TestClient(app)


def _wait(job_id: str, tries: int = 40):
    for _ in range(tries):
        r = client.get(f"/convert/{job_id}")
        data = r.json()
        if data["status"] in ("done", "error"):
            return data
        import time
        time.sleep(0.25)
    return {"status": "timeout"}


def test_reject_bad_extension():
    r = client.post("/convert", files={"file": ("a.txt", b"x", "text/plain")},
                    data={"target": "svg"})
    assert r.status_code in (400, 422)


def test_reject_bad_target():
    f = FIXTURES / "quadroring.ai"
    with open(f, "rb") as fh:
        r = client.post("/convert", files={"file": ("q.ai", fh, "application/octet-stream")},
                        data={"target": "png"})
    assert r.status_code == 422


def test_ai_pdf_passthrough():
    """quadroring.ai = %PDF-1.5 → target=pdf работает без движков."""
    f = FIXTURES / "quadroring.ai"
    with open(f, "rb") as fh:
        r = client.post("/convert", files={"file": ("q.ai", fh, "application/octet-stream")},
                        data={"target": "pdf"})
    assert r.status_code == 200, r.text
    job_id = r.json()["job_id"]
    data = _wait(job_id)
    assert data["status"] == "done", data
    assert data["result_url"]
    # Файл реально существует и непустой.
    out = ROOT / "data" / "out" / job_id / "result.pdf"
    assert out.exists() and out.stat().st_size > 1000


@pytest.mark.skipif(not inkscape_available(),
                    reason="Inkscape не найден")
def test_ai_to_svg_via_inkscape():
    f = FIXTURES / "quadroring.ai"
    with open(f, "rb") as fh:
        r = client.post("/convert", files={"file": ("q.ai", fh, "application/octet-stream")},
                        data={"target": "svg"})
    assert r.status_code == 200, r.text
    data = _wait(r.json()["job_id"])
    assert data["status"] == "done", data
    out = ROOT / "data" / "out" / r.json()["job_id"] / "result.svg"
    assert out.exists() and out.stat().st_size > 1000


def test_corrupt_file_error():
    r = client.post("/convert",
                    files={"file": ("bad.ai", b"this is not a vector file at all " * 10,
                                    "application/octet-stream")},
                    data={"target": "pdf"})
    assert r.status_code == 200
    data = _wait(r.json()["job_id"])
    assert data["status"] == "error"
    assert data["error"] and "Не удалось разобрать" in data["error"]


def test_parallel_jobs():
    jobs = []
    f = FIXTURES / "quadroring.ai"
    with open(f, "rb") as fh:
        content = fh.read()
    for i in range(3):
        r = client.post("/convert",
                        files={"file": (f"q{i}.ai", content, "application/octet-stream")},
                        data={"target": "pdf"})
        assert r.status_code == 200
        jobs.append(r.json()["job_id"])
    assert len(set(jobs)) == 3
    for jid in jobs:
        data = _wait(jid)
        assert data["status"] == "done", data


def test_gs_availability_flag():
    # Не падает; флаг используется skipif.
    assert gs_available() in (True, False)
