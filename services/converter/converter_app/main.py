# -*- coding: utf-8 -*-
"""FastAPI-сервис конвертации AI/CDR/EPS → SVG/PDF."""
import shutil
import threading
from pathlib import Path

from fastapi import FastAPI, File, Form, HTTPException, UploadFile
from fastapi.staticfiles import StaticFiles

from .convert import ConversionError, convert, _file_size_ok
from .jobs import JobQueue

BASE = Path(__file__).resolve().parent.parent
DATA = BASE / "data"
OUT = DATA / "out"
OUT.mkdir(parents=True, exist_ok=True)

app = FastAPI(title="Препресс-Планер: конвертация", version="0.1.0")
queue = JobQueue(OUT)

ALLOWED = {".ai", ".cdr", ".eps"}
MAX_MB = 50


def _worker(job_id: str, src_path: Path, target: str):
    job = queue.get(job_id)
    if job is None:
        return
    queue.set_running(job)
    job_dir = OUT / job_id
    job_dir.mkdir(parents=True, exist_ok=True)
    work = job_dir / "work"  # в workspace: системный temp вне песочницы
    work.mkdir(parents=True, exist_ok=True)
    try:
        # ASCII-пути для движков (русские имена ломают Inkscape/GS).
        safe_in = work / f"input{src_path.suffix.lower()}"
        shutil.copyfile(src_path, safe_in)
        result = convert(safe_in, target, work)
        final = job_dir / f"result.{target}"
        shutil.copyfile(result, final)
        queue.set_done(job, final)
    except ConversionError as e:
        queue.set_error(job, str(e))
    except Exception as e:  # noqa: BLE001
        queue.set_error(job, f"Внутренняя ошибка: {e}")
    finally:
        try:
            src_path.unlink(missing_ok=True)
        except Exception:
            pass


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
            detail=f"Файл больше {MAX_MB} МБ — конвертация не выполняется",
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
