# Агент 10 — Сервис конвертации (services/converter/)

## Роль (Ф4)
FastAPI-сервис: AI/CDR/EPS → SVG/PDF. Переиспользует парсеры `cam_pipeline` (эталон). Docker-образ python:3.12 + inkscape/ghostscript.

## Создаваемые файлы
```
services/converter/app/main.py        # FastAPI: POST /convert, GET /convert/{job_id}
services/converter/app/jobs.py        # фоновая очередь (asyncio/thread), статусы pending|running|done|error
services/converter/app/convert.py     # вызов cam_pipeline парсеров (ai/eps/cdr) → svg/pdf
services/converter/requirements.txt   # fastapi, uvicorn, python-multipart
services/converter/Dockerfile
services/converter/tests/test_convert.py  # pytest: .ai/.cdr/.eps из fixtures/
```

## API
- `POST /convert` (multipart `file`, `target` = svg|pdf) → `{"job_id": "…"}`; валидация расширения (.ai/.cdr/.eps) и размера (≤ 50 МБ).
- `GET /convert/{job_id}` → `{"status": …, "result_url": …, "error": "русское сообщение"|null}`.
- Результаты — в `data/out/<job_id>/` (отдаются статикой).
- Каскад парсеров из `cam_pipeline/src/parser/ai_parser.py` (4 попытки), `eps_parser.py`, `inkscape_parser.py`; временные ASCII-пути для русских имён; CREATE_NO_WINDOW.
- Ошибки — человекочитаемые на русском («Не удалось разобрать файл: …»).

## Тесты (pytest)
1. `fixtures/quadroring.ai` → svg/pdf успешно (статус done, файл непустой, XML/PDF валиден).
2. `fixtures/quadroring.cdr` → svg (если движки есть) — иначе тест пропускается с пометкой.
3. Битый файл → error с русским текстом; неверное расширение → 422/400.
4. Очередь: 3 параллельных запроса завершаются корректно.

## Критерии приёмки
1. `pytest services/converter/tests` зелёный (python из cam_pipeline venv или системный с fastapi). 2. Docker-образ собирается (если доступен docker — иначе Dockerfile проверяется ревью).

## Движки и поиск Ghostscript (реализовано 2026-09-03)
- `convert.py` ищет движки автоматически: `PP_GHOSTSCRIPT` → PATH (`gswin64c/gswin32c/gs`) →
  каталоги `C:\Program Files\gs`, `C:\Program Files (x86)\gs` и
  `cam_pipeline\ghostscript_engine` (по `<версия>/bin/gswin*`). `PP_INKSCAPE` без env
  фолбэчится на `cam_pipeline\inkscape_engine\bin\inkscape.exe` репозитория.
- EPS-каскад: Ghostscript → PDF (`-dSAFER -sDEVICE=pdfwrite`) → при target=svg ещё
  Inkscape из PDF. Проверено вручную по HTTP: EPS → done → svg (на Ghostscript 8.64,
  `C:\Program Files (x86)\gs`). Ошибка «Ghostscript не найден» — с подсказкой по
  установке/env.
- ВАЖНО истории: Ghostscript «не стартует 0xC0000142» — про старую машину; на текущей
  GS 8.64 запускается, тесты реального EPS-прогона добавить в pytest (сейчас покрыт
  только флаг gs_available).
