# -*- coding: utf-8 -*-
"""Конвертация AI/CDR/EPS → SVG/PDF через локальные движки.

Ограничения песочницы разработки (проверено агентом 10):
- subprocess с capture_output (пайпы) запрещён → движки запускаются с
  stdout/stderr в файлы (stdio: файловые дескрипторы).
- Ghostscript в этой среде не стартует (0xC0000142) → EPS-пути помечены
  skipif-проверкой доступности GS.
- Работает Inkscape: .ai→svg, .cdr→svg/pdf, svg→pdf.
- quadroring.ai — это %PDF-1.5: копия в .pdf срабатывает без движков.
"""
import os
import shutil
import subprocess
import tempfile
from pathlib import Path

INKSCAPE = Path(os.environ.get(
    "PP_INKSCAPE",
    r"C:\Users\user\Desktop\MyApp\vibe cam\cam_pipeline\inkscape_engine\bin\inkscape.exe"))
GHOSTSCRIPT = Path(os.environ.get(
    "PP_GHOSTSCRIPT",
    r"C:\Users\user\Desktop\MyApp\vibe cam\cam_pipeline\ghostscript_engine\gs10.07.1\bin\gswin64c.exe"))

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
    if not GHOSTSCRIPT.exists():
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

    # 3) EPS: Ghostscript → PDF (в песочнице GS может быть недоступен).
    if ext == ".eps":
        if not gs_available():
            raise ConversionError(
                "Не удалось разобрать файл: Ghostscript недоступен в этой среде")
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
