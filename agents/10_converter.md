# Агент 10 — Сервис конвертации (services/converter/)

> **Актуализация 2026-09-07 (HEAD 448dcba):** статус — актуально (реализовано и развёрнуто).
> - Реальный деплой: Docker на 193.233.193.12, порт 8120; результаты — статика `/data` (`deploy/docker-compose.yml`, `services/converter/Dockerfile`).
> - Конфигурация: `PP_JOB_STORE=file`, `PP_JOB_TTL_HOURS`, `PP_MAX_MB`; в Dockerfile/деплое — `uvicorn --workers 2`.
> - Клиент (app): дефолтный адрес `http://193.233.193.12:8120` (`env PP_CONVERTER_URL` на desktop; на web — относительный URL через прокси :8081); кнопки «Запустить сервер»/«Проверить сервер» на экране «Геометрия» (коммиты `15fe44a`, `1055103`, `ae0701a`; `app/lib/src/converter/`).
> - Безопасность: сервис без авторизации и лимитов — риск аудита 2026-09-07, исправления отложены (см. `SECURITY.md`).

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

## Удалённый сервер и горизонтальное масштабирование (2026-)
- Цель: конвертер на Linux-сервере (Docker), рабочие ПК без Python; путь — общий
  сервер, затем N воркеров.
- `convert.py`: кросс-платформенный поиск движков — `PP_INKSCAPE/PP_GHOSTSCRIPT`
  (если есть) → `cam_pipeline\…` репозитория → PATH (`inkscape`, `gs`, Windows-имена).
- `jobs.py`: интерфейс очереди с двумя реализациями — `JobQueue` (memory, тесты/один
  процесс) и `FileJobQueue` (статусы JSON в `<data>/jobs/<id>.json`, атомарная запись
  tmp+os.replace, TTL-чистка фоновым потоком). Методы принимают `job_id`, а не объект —
  несколько процессов/реплик видят чужие задачи.
- `main.py`: env-конфиг `PP_DATA_DIR`, `PP_JOB_STORE` (memory|file), `PP_JOB_TTL_HOURS`,
  `PP_MAX_MB`; эндпоинт `GET /healthz` (статус + наличие движков); shutdown через
  lifespan.
- Dockerfile: python:3.12-slim + apt inkscape/ghostscript/fonts-dejavu (самодостаточный
  образ), `PP_JOB_STORE=file`, `--workers 2`. docker-compose.yml: volume `converter-data`
  + healthcheck на /healthz.
- Масштабирование: один хост — `--workers N`; несколько хостов — swarm
  (`docker stack deploy`, `service scale`) с общим томом (NFS/Ceph) либо S3/Redis-слой
  вместо локальных файлов. API не меняется.
- Клиент (app): адрес сервера — env `PP_CONVERTER_URL` или шестерёнка на экране
  «Геометрия»; кнопка «Запустить сервер» поднимает локальный uvicorn, только если адрес
  локальный (127.0.0.1/localhost).
