# -*- coding: utf-8 -*-
"""Тесты file-очереди задач (основа горизонтального масштабирования)."""
import sys
import time
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]  # services/converter
sys.path.insert(0, str(ROOT))

from converter_app.jobs import FileJobQueue, JobQueue  # noqa: E402


def test_memory_queue_lifecycle(tmp_path):
    q = JobQueue()
    job = q.create()
    assert q.get(job.job_id) is not None
    assert q.set_running(job.job_id) is not None
    assert q.get(job.job_id).status == "running"
    q.set_done(job.job_id, tmp_path / "result.pdf")
    j = q.get(job.job_id)
    assert j.status == "done" and j.result_path.endswith("result.pdf")
    q.sweep(-1, tmp_path)  # отрицательный TTL → всё устарело
    assert q.get(job.job_id) is None


def test_file_queue_persists(tmp_path):
    q = FileJobQueue(tmp_path, ttl_seconds=0)  # без фоновой чистки
    job = q.create()
    assert (tmp_path / "jobs" / f"{job.job_id}.json").exists()
    q.set_running(job.job_id)
    q.set_done(job.job_id, tmp_path / "out" / job.job_id / "result.svg")
    j = q.get(job.job_id)
    assert j is not None
    assert j.status == "done"
    assert j.result_path and j.result_path.endswith("result.svg")

    # «Другой процесс» (новый экземпляр очереди) видит ту же задачу.
    q2 = FileJobQueue(tmp_path, ttl_seconds=0)
    j2 = q2.get(job.job_id)
    assert j2 is not None and j2.status == "done"
    q2.close()


def test_file_queue_error_and_ttl(tmp_path):
    q = FileJobQueue(tmp_path, ttl_seconds=0)
    job = q.create()
    q.set_error(job.job_id, "Бум")
    j = q.get(job.job_id)
    assert j.status == "error" and j.error == "Бум"
    # TTL: задача с updated_at в прошлом удаляется.
    q.sweep(-1, tmp_path / "out")
    assert q.get(job.job_id) is None
    q.close()


def test_file_queue_sweep_removes_result_dir(tmp_path):
    q = FileJobQueue(tmp_path, ttl_seconds=0)
    job = q.create()
    out = tmp_path / "out" / job.job_id
    out.mkdir(parents=True)
    (out / "result.pdf").write_bytes(b"%PDF-x")
    q.set_done(job.job_id, out / "result.pdf")
    # Подсовываем старое время обновления (правка файла на диске: _write
    # сам ставит updated_at=now, поэтому напрямую через очередь нельзя).
    import json
    p = tmp_path / "jobs" / f"{job.job_id}.json"
    data = json.loads(p.read_text(encoding="utf-8"))
    data["updated_at"] = time.time() - 1000
    p.write_text(json.dumps(data), encoding="utf-8")
    q.sweep(60, tmp_path / "out")
    assert q.get(job.job_id) is None
    assert not out.exists()
    q.close()
