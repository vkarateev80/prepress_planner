# -*- coding: utf-8 -*-
"""FastAPI-сервис конвертации AI/CDR/EPS → SVG/PDF.

Конфигурация через env:
  PP_DATA_DIR        — каталог данных (по умолчанию <сервис>/data); при
                       горизонтальном масштабировании — общий том (volume).
  PP_JOB_STORE       — memory | file (по умолчанию memory). file хранит
                       статусы задач JSON-файлами в PP_DATA_DIR/jobs и
                       позволяет нескольким воркерам видеть чужие задачи.
  PP_JOB_TTL_HOURS   — TTL задач/результатов для file-очереди (по умолч. 24).
  PP_MAX_MB          — лимит размера файла (по умолчанию 50).
  PP_INKSCAPE / PP_GHOSTSCRIPT — пути к движкам (иначе авто-поиск).
"""
import os
import shutil
import threading
from contextlib import asynccontextmanager
from pathlib import Path

from fastapi import FastAPI, File, Form, HTTPException, UploadFile
from fastapi.staticfiles import StaticFiles

from .convert import ConversionError, convert, _file_size_ok
from .convert import GHOSTSCRIPT, INKSCAPE
from .jobs import make_job_store

BASE = Path(__file__).resolve().parent.parent
DATA = Path(os.environ.get("PP_DATA_DIR") or (BASE / "data"))
OUT = DATA / "out"
OUT.mkdir(parents=True, exist_ok=True)

_store_kind = os.environ.get("PP_JOB_STORE", "memory").strip().lower()
_ttl_hours = float(os.environ.get("PP_JOB_TTL_HOURS", "24").strip() or 24)
queue = make_job_store(_store_kind, DATA)

ALLOWED = {".ai", ".cdr", ".eps"}
MAX_MB = float(os.environ.get("PP_MAX_MB", "50").strip() or 50)


@asynccontextmanager
async def _lifespan(app: FastAPI):
    yield
    close = getattr(queue, "close", None)
    if close is not None:
        close()


app = FastAPI(
    title="Препресс-Планер: конвертация", version="0.2.0",
    lifespan=_lifespan)


def _worker(job_id: str, src_path: Path, target: str):
    if queue.set_running(job_id) is None:
        return
    job_dir = OUT / job_id
    job_dir.mkdir(parents=True, exist_ok=True)
    work = job_dir / "work"  # ASCII-пути для движков (русские имена ломают их)
    work.mkdir(parents=True, exist_ok=True)
    try:
        # ASCII-пути для движков.
        safe_in = work / f"input{src_path.suffix.lower()}"
        shutil.copyfile(src_path, safe_in)
        result = convert(safe_in, target, work)
        final = job_dir / f"result.{target}"
        shutil.copyfile(result, final)
        queue.set_done(job_id, final)
    except ConversionError as e:
        queue.set_error(job_id, str(e))
    except Exception as e:  # noqa: BLE001
        queue.set_error(job_id, f"Внутренняя ошибка: {e}")
    finally:
        try:
            src_path.unlink(missing_ok=True)
        except Exception:
            pass


@app.get("/healthz")
def healthz():
    """Healthcheck для Docker/балансировщика."""
    return {
        "status": "ok",
        "engines": {
            "inkscape": INKSCAPE is not None and INKSCAPE.exists(),
            "ghostscript": GHOSTSCRIPT is not None and GHOSTSCRIPT.exists(),
        },
        "job_store": _store_kind,
    }


@app.post("/convert")
async def create_convert(
    file: UploadFile = File(...),
    target: str = Form("svg"),
):
    target = target.lower()
    if target not in ("svg", "pdf"):
        raise HTTPException(status_code=422, detail="Целевой формат: svg или pdf")
    name = file.filename or ""
    ext = Path(name).suffix.lower()
    if ext not in ALLOWED:
        raise HTTPException(
            status_code=400,
            detail=f"Формат {ext or 'неизвестный'} не поддерживается: "
                   f"допустимы .ai, .cdr, .eps",
        )
    # Сохраняем во временный файл (уникальный — параллельные запросы)
    # и проверяем размер.
    import uuid
    tmp = OUT / f"_upload_{uuid.uuid4().hex[:8]}{ext}"
    with open(tmp, "wb") as f:
        shutil.copyfileobj(file.file, f)
    if not _file_size_ok(tmp, MAX_MB):
        tmp.unlink(missing_ok=True)
        raise HTTPException(
            status_code=400,
            detail=f"Файл больше {MAX_MB:g} МБ — конвертация не выполняется",
        )
    job = queue.create()
    threading.Thread(
        target=_worker, args=(job.job_id, tmp, target), daemon=True
    ).start()
    return {"job_id": job.job_id}


@app.get("/convert/{job_id}")
async def get_status(job_id: str):
    job = queue.get(job_id)
    if job is None:
        raise HTTPException(status_code=404, detail="Задача не найдена")
    return {
        "status": job.status,
        "result_url": (
            f"/data/out/{job.job_id}/result.{Path(job.result_path).suffix.lstrip('.')}"
            if job.result_path else None
        ),
        "error": job.error,
    }


# Статика результатов: /data/out/<job_id>/result.svg|pdf
app.mount("/data", StaticFiles(directory=str(DATA)), name="data")
