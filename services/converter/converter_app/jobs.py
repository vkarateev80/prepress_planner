# -*- coding: utf-8 -*-
"""Фоновая очередь задач конвертации (in-memory, статусы и результаты)."""
import threading
import uuid
from dataclasses import dataclass, field
from pathlib import Path


@dataclass
class Job:
    job_id: str
    status: str = "pending"  # pending | running | done | error
    result_path: str | None = None
    error: str | None = None
    log: list[str] = field(default_factory=list)


class JobQueue:
    def __init__(self, out_root: Path):
        self.out_root = out_root
        self._jobs: dict[str, Job] = {}
        self._lock = threading.Lock()

    def create(self) -> Job:
        job = Job(job_id=uuid.uuid4().hex[:12])
        with self._lock:
            self._jobs[job.job_id] = job
        return job

    def get(self, job_id: str) -> Job | None:
        with self._lock:
            return self._jobs.get(job_id)

    def set_running(self, job: Job):
        with self._lock:
            job.status = "running"

    def set_done(self, job: Job, result_path: Path):
        with self._lock:
            job.status = "done"
            job.result_path = str(result_path)

    def set_error(self, job: Job, message: str):
        with self._lock:
            job.status = "error"
            job.error = message
