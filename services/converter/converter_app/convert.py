# -*- coding: utf-8 -*-
"""Конвертация AI/CDR/EPS → SVG/PDF через локальные движки.

Ограничения песочницы разработки (проверено агентом 10):
- subprocess с capture_output (пайпы) запрещён → движки запускаются с
  stdout/stderr в файлы (stdio: файловые дескрипторы).
- Ghostscript ищется автоматически (PP_GHOSTSCRIPT или стандартные пути
  установки; проверено на Ghostscript 8.64 в "C:\Program Files (x86)\gs").
- Работает Inkscape: .ai→svg, .cdr→svg/pdf, svg→pdf, pdf→svg.
- quadroring.ai — это %PDF-1.5: копия в .pdf срабатывает без движков.
"""
import glob
import os
import shutil
import subprocess
import tempfile
from pathlib import Path

_REPO = Path(__file__).resolve().parents[3]


def _default_inkscape() -> Path:
    """Inkscape из cam_pipeline репозитория (если есть), иначе старый дефолт."""
    cand = _REPO / "cam_pipeline" / "inkscape_engine" / "bin" / "inkscape.exe"
    if cand.exists():
        return cand
    return Path(
        r"C:\Users\user\Desktop\MyApp\vibe cam\cam_pipeline\inkscape_engine\bin\inkscape.exe")


INKSCAPE = Path(os.environ.get("PP_INKSCAPE") or _default_inkscape())

# Базы установки Ghostscript (версия подбирается автоматически, старшая первой):
# системные каталоги + движок cam_pipeline (если присутствует в репозитории).
_GS_BASES = [
    Path(r"C:\Program Files\gs"),
    Path(r"C:\Program Files (x86)\gs"),
]
_cam_gs = _REPO / "cam_pipeline" / "ghostscript_engine"
if _cam_gs.is_dir():
    _GS_BASES.append(_cam_gs)


def find_ghostscript() -> "Path | None":
    """Поиск исполняемого файла Ghostscript.

    Приоритет: PP_GHOSTSCRIPT (если существует) → PATH → каталоги установки
    C:\\Program Files[ (x86)]\\gs\\<версия>\\bin и cam_pipeline\\ghostscript_engine.
    Если движок не найден — возвращается None (конвертер EPS даст понятную
    ошибку с подсказкой).
    """
    env_gs = os.environ.get("PP_GHOSTSCRIPT", "").strip()
    if env_gs:
        p = Path(env_gs)
        if p.exists():
            return p
    for name in ("gswin64c.exe", "gswin32c.exe", "gs.exe"):
        found = shutil.which(name)
        if found:
            return Path(found)
    for base in _GS_BASES:
        if not base.is_dir():
            continue
        # <base>/<версия>/bin/gswin64c.exe | gswin32c.exe
        for bin_dir in glob.glob(str(base / "*" / "bin")):
            for name in ("gswin64c.exe", "gswin32c.exe", "gs.exe"):
                cand = Path(bin_dir) / name
                if cand.exists():
                    return cand
    return None


GHOSTSCRIPT = find_ghostscript()

CREATE_NO_WINDOW = 0x08000000 if os.name == "nt" else 0


def _run_file_stdio(cmd, log_path: Path) -> int:
    """Запуск команды с файловым stdio (пайпы в песочнице запрещены)."""
    with open(log_path, "w", encoding="utf-8", errors="replace") as log:
        proc = subprocess.run(
            [str(c) for c in cmd],
            stdout=log,
            stderr=subprocess.STDOUT,
            creationflags=CREATE_NO_WINDOW,
        )
    return proc.returncode


def gs_available() -> bool:
    if GHOSTSCRIPT is None or not GHOSTSCRIPT.exists():
        return False
    try:
        with tempfile.TemporaryDirectory() as td:
            log = Path(td) / "gsver.log"
            return _run_file_stdio([GHOSTSCRIPT, "--version"], log) == 0
    except Exception:
        return False


def inkscape_available() -> bool:
    return INKSCAPE.exists()


def _is_pdf_compatible(path: Path) -> bool:
    try:
        with open(path, "rb") as f:
            return f.read(5) == b"%PDF-"
    except Exception:
        return False


def _file_size_ok(path: Path, limit_mb: int = 50) -> bool:
    return path.stat().st_size <= limit_mb * 1024 * 1024


class ConversionError(Exception):
    """Русское сообщение об ошибке конвертации."""


def convert(src: Path, target: str, work_dir: Path) -> Path:
    """Конвертация файла [src] в SVG или PDF. Возвращает путь результата.

    work_dir — временный ASCII-каталог для движков и логов.
    """
    target = target.lower()
    if target not in ("svg", "pdf"):
        raise ConversionError(f"Целевой формат не поддерживается: {target}")
    ext = src.suffix.lower()
    if ext not in (".ai", ".cdr", ".eps"):
        raise ConversionError(f"Формат не поддерживается: {ext or src.name}")

    log = work_dir / "log.txt"
    safe_in = src

    # 1) AI: если PDF-совместим — достаточно копии в .pdf (Dart парсит PDF).
    if ext == ".ai" and _is_pdf_compatible(src):
        out = work_dir / f"result.{target}"
        if target == "pdf":
            shutil.copyfile(safe_in, out)
            return out
        # svg: через Inkscape.
        if not inkscape_available():
            raise ConversionError(
                "AI→SVG требует Inkscape, который не найден; попробуйте target=pdf")
        rc = _run_file_stdio(
            [INKSCAPE, safe_in, "--export-type=svg",
             "--export-text-to-path", "-o", out], log)
        if rc != 0 or not out.exists():
            raise ConversionError(
                f"Не удалось разобрать файл: Inkscape завершился с кодом {rc} "
                f"(см. {log.name})")
        return out

    # 1b) AI без PDF-совместимости: каскад Inkscape (как ai_parser.py: PDF →
    #     Inkscape → EPS/GS). Битый файл не откроется — понятная ошибка.
    if ext == ".ai":
        if inkscape_available():
            out = work_dir / f"result.{target}"
            rc = _run_file_stdio(
                [INKSCAPE, safe_in, f"--export-type={target}",
                 "--export-text-to-path", "-o", out], log)
            if rc == 0 and out.exists():
                return out
        raise ConversionError(
            "Не удалось разобрать файл: AI не содержит PDF-совместимого потока "
            "и не открывается Inkscape (пересохраните в Illustrator с "
            "«Create PDF Compatible File» или конвертируйте в SVG)")

    # 2) CDR: через Inkscape.
    if ext == ".cdr":
        if not inkscape_available():
            raise ConversionError("CDR требует Inkscape, который не найден")
        out = work_dir / f"result.{target}"
        rc = _run_file_stdio(
            [INKSCAPE, safe_in, f"--export-type={target}",
             "--export-text-to-path", "-o", out], log)
        if rc != 0 or not out.exists():
            raise ConversionError(
                f"Не удалось разобрать файл: Inkscape завершился с кодом {rc} "
                f"(см. {log.name})")
        return out

    # 3) EPS: Ghostscript → PDF (GS ищется автоматически; если его нет —
    #    понятная ошибка с подсказкой).
    if ext == ".eps":
        if not gs_available():
            raise ConversionError(
                "Не удалось разобрать файл: Ghostscript не найден в этой "
                "среде. Установите Ghostscript или укажите PP_GHOSTSCRIPT "
                "(проверяются C:\\Program Files\\gs и C:\\Program Files "
                "(x86)\\gs).")
        mid = work_dir / "mid.pdf"
        out = work_dir / f"result.{target}"
        rc = _run_file_stdio(
            [GHOSTSCRIPT, "-dNOPAUSE", "-dBATCH", "-dSAFER",
             "-sDEVICE=pdfwrite", f"-sOutputFile={mid}", safe_in], log)
        if rc != 0 or not mid.exists():
            raise ConversionError(
                f"Не удалось разобрать файл: Ghostscript завершился с кодом {rc} "
                f"(см. {log.name})")
        if target == "pdf":
            shutil.copyfile(mid, out)
            return out
        if not inkscape_available():
            raise ConversionError("EPS→SVG требует Inkscape, который не найден")
        rc2 = _run_file_stdio(
            [INKSCAPE, mid, "--export-type=svg", "--export-text-to-path",
             "-o", out], log)
        if rc2 != 0 or not out.exists():
            raise ConversionError(
                f"Не удалось разобрать файл: Inkscape завершился с кодом {rc2} "
                f"(см. {log.name})")
        return out

    raise ConversionError(f"Формат не поддерживается: {ext}")
