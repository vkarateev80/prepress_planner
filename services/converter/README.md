# Сервис конвертации (converter)

FastAPI: AI/CDR/EPS → SVG/PDF. Использует локальные движки (Inkscape,
Ghostscript). Сам сервис только конвертирует формат: конвейер
«файл → лечение → раскрой → ТЭО» живёт в домене `packages/core` и
приложении `app`.

> Статус на 2026-09-07: сервис развёрнут в проде (`deploy/`, порт 8120).
> **Авторизации у сервиса нет — он публично доступен**; статика `/data`
> отдаёт весь `PP_DATA_DIR` (в т.ч. `out/<id>/work/` с копией исходника и
> `jobs/*.json` при `PP_JOB_STORE=file`), лимиты и таймауты движков не
> настроены, размер проверяется после полной записи файла — см. разделы 1–2
> `SECURITY.md` в корне репозитория.

## API

- `POST /convert` — multipart `file` (`.ai|.cdr|.eps`) + `target=svg|pdf`
  (по умолчанию `svg`). Файл сначала целиком записывается во временный файл,
  затем проверяется лимит `PP_MAX_MB`; при превышении — 400. При успехе →
  `{"job_id": "…"}` (12 hex-символов, `uuid4().hex[:12]`).
- `GET /convert/{job_id}` → `{"status": "pending|running|done|error",
  "result_url": "/data/out/<id>/result.<ext>", "error": null|"…"}`
  (404, если задача не найдена).
- `GET /healthz` → `{"status": "ok", "engines": {"inkscape": bool,
  "ghostscript": bool}, "job_store": "memory|file"}` (для Docker/балансировщика).
- Статика результатов: `GET /data/out/<job_id>/result.<ext>`
  (`app.mount("/data", …)` отдаёт весь каталог данных `PP_DATA_DIR`).

## Пример

```bash
curl -F "file=@fixtures/quadroring.ai" -F "target=svg" http://localhost:8120/convert
curl http://localhost:8120/convert/<job_id>
```

## Движки (env или авто-поиск)

Inkscape: `PP_INKSCAPE` → `cam_pipeline\inkscape_engine` (если есть в
репозитории) → PATH (`inkscape`). Ghostscript: `PP_GHOSTSCRIPT` → PATH
(`gs`/`gswin64c.exe`/`gswin32c.exe`) → каталоги установки
`C:\Program Files[ (x86)]\gs\<версия>\bin` и `cam_pipeline\ghostscript_engine`.

```bash
set PP_INKSCAPE=C:\path\to\inkscape.exe
set PP_GHOSTSCRIPT=C:\path\to\gswin64c.exe
```

Поведение по форматам (см. `convert.py`):
- **.ai** — PDF-совместимый: в PDF — простая копия (движки не нужны); в SVG —
  через Inkscape. Без PDF-потока — каскад Inkscape, иначе понятная ошибка.
- **.cdr** — через Inkscape.
- **.eps** — Ghostscript → PDF (`-dSAFER`), далее SVG при необходимости через
  Inkscape. Без движков — понятная ошибка с подсказкой.

Без движков сервис работает (частично: PDF-совместимый .ai → PDF), а тесты
реальных прогонов Inkscape/Ghostscript помечены `skipif` по доступности движков.

## Локальный запуск (Windows, разработка)

```bash
pip install -r requirements.txt
uvicorn converter_app.main:app --port 8120
```

## Развёртывание в Docker

Образ `services/converter/Dockerfile` самодостаточен: движки ставятся из apt
(inkscape, ghostscript), в образе заданы `PP_JOB_STORE=file`, `PP_JOB_TTL_HOURS=24`
и `uvicorn --workers 2` — один инстанс конвертирует параллельно, статусы задач
видны из любого процесса (файловая очередь + общий том).

Стек целиком поднимается из `deploy/docker-compose.yml` (рекомендуется) или
`services/docker-compose.yml`:

```bash
cd deploy                      # либо cd services
cp .env.example .env           # при необходимости
docker compose up -d --build
curl http://127.0.0.1:8120/healthz
# {"status":"ok","engines":{"inkscape":true,"ghostscript":true},"job_store":"file"}
```

### Переменные окружения

| Переменная | По умолчанию | Назначение |
|---|---|---|
| `PP_DATA_DIR` | `<сервис>/data` | Каталог данных (результаты `out/`, статусы `jobs/`) — общий volume |
| `PP_JOB_STORE` | `memory` | `memory` — один процесс; `file` — статусы JSON на общем томе |
| `PP_JOB_TTL_HOURS` | `24` | TTL задач и результатов (file-очередь, фоновая чистка) |
| `PP_MAX_MB` | `50` | Лимит размера файла (проверяется ПОСЛЕ записи) |
| `PP_INKSCAPE`, `PP_GHOSTSCRIPT` | авто-поиск | Явные пути к движкам |

## Очередь задач и масштабирование

Хранилища (`converter_app/jobs.py`) — одинаковый интерфейс:
- `JobQueue` (memory): статусы в памяти процесса (тесты, один процесс);
- `FileJobQueue` (file): каждая задача — JSON `<data>/jobs/<id>.json`
  (атомарная перезапись `tmp + os.replace`), устаревшее чистит фоновый поток.
  При общем томе несколько процессов/реплик видят статусы друг друга.

Архитектура готова к N воркерам: один хост — `--workers 2` в Dockerfile
(можно поднять до числа ядер минус 1); несколько реплик/хостов — общий том
данных (`PP_DATA_DIR`) для всех реплик + file-очередь, порт наружу публикует
балансировщик/ingress. Если общего тома нет — слой `jobs.py` и статика `/data`
спроектированы так, что хранилище подменяется (S3/Redis), не меняя API.

## Приложение (клиент)

Desktop: клиент по умолчанию обращается к прод-серверу
`http://193.233.193.12:8120` (env `PP_CONVERTER_URL` или кнопка-шестерёнка на
экране «Геометрия»). Web: в браузере env недоступен (`env_web.dart` всегда
возвращает ''), поэтому клиент ходит относительными путями `/convert` и
`/data` на тот же origin — их проксирует nginx (см. `deploy/`). На рабочих ПК
Python и движки не нужны — они обращаются к удалённому серверу. Дополнительно
(desktop, локальный адрес) UI может поднять локальный uvicorn — см.
`app/lib/src/converter/converter_server.dart`.

## Тесты

```bash
python -m pytest tests -q
```
