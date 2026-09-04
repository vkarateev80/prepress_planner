# -*- coding: utf-8 -*-
"""Очередь задач конвертации.

Два хранилища с одинаковым интерфейсом (методы принимают job_id, а не объект —
это позволяет нескольким процессам/репликам работать с одной очередью):

- JobQueue (memory): статусы в памяти процесса. Для тестов и одного процесса.
- FileJobQueue: статусы — JSON-файлы в <data>/jobs/<id>.json, запись атомарная
  (tmp + os.replace). При общем томе (docker volume / NFS) несколько реплик
  видят статусы друг друга — база для горизонтального масштабирования.
  Устаревшие задачи и их результаты удаляются фоновым потоком (TTL).

Результаты конвертации пишутся в <data>/out/<id>/result.<ext> и раздаются
статикой /data — тоже с общего тома.
"""
import json
import os
import shutil
import threading
import time
import uuid
from dataclasses import dataclass, field
from pathlib import Path

_STATUSES = ("pending", "running", "done", "error")


@dataclass
class Job:
    job_id: str
    status: str = "pending"  # pending | running | done | error
    result_path: str | None = None
    error: str | None = None
    log: list[str] = field(default_factory=list)
    created_at: float = field(default_factory=time.time)
    updated_at: float = field(default_factory=time.time)

    def to_json(self) -> dict:
        return {
            "job_id": self.job_id,
            "status": self.status,
            "result_path": self.result_path,
            "error": self.error,
            "log": self.log,
            "created_at": self.created_at,
            "updated_at": self.updated_at,
        }

    @staticmethod
    def from_json(j: dict) -> "Job":
        return Job(
            job_id=j.get("job_id", ""),
            status=j.get("status", "pending"),
            result_path=j.get("result_path"),
            error=j.get("error"),
            log=list(j.get("log") or []),
            created_at=float(j.get("created_at") or time.time()),
            updated_at=float(j.get("updated_at") or time.time()),
        )


def make_job_store(kind: str, data_dir: Path):
    """Фабрика хранилища: 'memory' | 'file'."""
    kind = (kind or "memory").strip().lower()
    if kind == "file":
        return FileJobQueue(data_dir)
    return JobQueue()


class JobQueue:
    """In-memory очередь: один процесс, быстрые тесты."""

    def __init__(self):
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

    def _mutate(self, job_id: str, **changes) -> Job | None:
        with self._lock:
            job = self._jobs.get(job_id)
            if job is None:
                return None
            for k, v in changes.items():
                setattr(job, k, v)
            job.updated_at = time.time()
            return job

    def set_running(self, job_id: str) -> Job | None:
        return self._mutate(job_id, status="running")

    def set_done(self, job_id: str, result_path: Path) -> Job | None:
        return self._mutate(job_id, status="done", result_path=str(result_path))

    def set_error(self, job_id: str, message: str) -> Job | None:
        return self._mutate(job_id, status="error", error=message)

    def sweep(self, max_age_seconds: float, out_root: Path):
        """In-memory: старые задачи забываем и чистим результаты на диске."""
        now = time.time()
        stale = []
        with self._lock:
            for job_id, job in self._jobs.items():
                if now - job.updated_at > max_age_seconds:
                    stale.append(job_id)
            for job_id in stale:
                self._jobs.pop(job_id, None)
        for job_id in stale:
            _rm_out(out_root / job_id)


class FileJobQueue:
    """Файловая очередь на общем томе: несколько процессов/реплик.

    Каждая задача — JSON в <data>/jobs/<job_id>.json. Переходы статусов —
    атомарная перезапись файла (tmp + os.replace), поэтому конкурентные
    читатели видят либо старую, либо новую версию, никогда — частичную.
    """

    def __init__(self, data_dir: Path, ttl_seconds: float = 24 * 3600,
                 sweep_interval_seconds: float = 900):
        self.jobs_dir = data_dir / "jobs"
        self.jobs_dir.mkdir(parents=True, exist_ok=True)
        self.ttl_seconds = ttl_seconds
        self._lock = threading.Lock()
        self._stop = threading.Event()
        self._sweeper = None
        if ttl_seconds > 0:
            self._sweeper = threading.Thread(
                target=self._sweep_loop, args=(sweep_interval_seconds,),
                daemon=True)
            self._sweeper.start()

    # ---- жизненный цикл фоновой чистки --------------------------------
    def _sweep_loop(self, interval: float):
        while not self._stop.wait(interval):
            try:
                self.sweep(self.ttl_seconds, self.jobs_dir.parent / "out")
            except Exception:
                pass  # чистка не должна ронять сервис

    def close(self):
        self._stop.set()

    # ---- интерфейс очереди --------------------------------------------
    def _path(self, job_id: str) -> Path:
        return self.jobs_dir / f"{job_id}.json"

    def create(self) -> Job:
        job = Job(job_id=uuid.uuid4().hex[:12])
        self._write(job)
        return job

    def get(self, job_id: str) -> Job | None:
        p = self._path(job_id)
        try:
            data = json.loads(p.read_text(encoding="utf-8"))
        except Exception:
            return None
        return Job.from_json(data) if isinstance(data, dict) else None

    def _write(self, job: Job):
        job.updated_at = time.time()
        p = self._path(job.job_id)
        tmp = p.with_suffix(".tmp")
        tmp.write_text(
            json.dumps(job.to_json(), ensure_ascii=False),
            encoding="utf-8")
        os.replace(tmp, p)

    def _mutate(self, job_id: str, **changes) -> Job | None:
        with self._lock:  # защита от гонок в пределах одного процесса
            job = self.get(job_id)
            if job is None:
                return None
            for k, v in changes.items():
                setattr(job, k, v)
            self._write(job)
            return job

    def set_running(self, job_id: str) -> Job | None:
        return self._mutate(job_id, status="running")

    def set_done(self, job_id: str, result_path: Path) -> Job | None:
        return self._mutate(job_id, status="done", result_path=str(result_path))

    def set_error(self, job_id: str, message: str) -> Job | None:
        return self._mutate(job_id, status="error", error=message)

    def sweep(self, max_age_seconds: float, out_root: Path):
        """Удаляем задачи старше TTL и их результаты."""
        now = time.time()
        if not self.jobs_dir.is_dir():
            return
        for p in self.jobs_dir.glob("*.json"):
            try:
                data = json.loads(p.read_text(encoding="utf-8"))
                if not isinstance(data, dict):
                    continue
                job = Job.from_json(data)
                if now - job.updated_at > max_age_seconds:
                    p.unlink(missing_ok=True)
                    _rm_out(out_root / job.job_id)
            except Exception:
                continue


def _rm_out(d: Path):
    try:
        if d.is_dir():
            shutil.rmtree(d, ignore_errors=True)
    except Exception:
        pass
