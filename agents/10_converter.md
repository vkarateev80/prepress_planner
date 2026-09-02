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
