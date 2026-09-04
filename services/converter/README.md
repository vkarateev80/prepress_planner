# Сервис конвертации (converter)

FastAPI: AI/CDR/EPS → SVG/PDF. Использует локальные движки (Inkscape,
Ghostscript) — эталон конвейера `cam_pipeline`.

## API

- `POST /convert` — multipart `file` (`.ai|.cdr|.eps`, ≤ 50 МБ) + `target=svg|pdf`
  → `{"job_id": "…"}`
- `GET /convert/{job_id}` → `{"status": "pending|running|done|error",
  "result_url": "/data/out/<id>/result.<ext>", "error": null|"…"}`
- `GET /healthz` → статус сервиса и наличие движков (для Docker/балансировщика)
- Результаты — в `data/out/<job_id>/` (статика на `/data`).

## Пример

```bash
curl -F "file=@fixtures/quadroring.ai" -F "target=svg" http://localhost:8120/convert
curl http://localhost:8120/convert/<job_id>
```

## Локальный запуск (Windows, разработка)

```bash
pip install -r requirements.txt
uvicorn converter_app.main:app --port 8120
```

Движки указываются env (иначе — авто-поиск: `PP_INKSCAPE` →
`cam_pipeline\inkscape_engine` → PATH; `PP_GHOSTSCRIPT` → PATH → стандартные
каталоги установки):

```bash
set PP_INKSCAPE=C:\path\to\inkscape.exe
set PP_GHOSTSCRIPT=C:\path\to\gswin64c.exe
```

Без движков сервис работает (PDF-совместимый .ai проходит без них), а тесты
реальных прогонов Inkscape/Ghostscript помечены `skipif` по доступности.

## Развёртывание на Linux-сервере (Docker)

Образ самодостаточен: движки ставятся из apt (inkscape, ghostscript). Данные —
в `PP_DATA_DIR` (volume), статусы задач — file-очередь на том же томе.

```bash
cd services/converter
docker compose up -d --build
curl http://localhost:8120/healthz
# {"status":"ok","engines":{"inkscape":true,"ghostscript":true},...}
```

Переменные окружения:

| Переменная | По умолчанию | Назначение |
|---|---|---|
| `PP_DATA_DIR` | `<сервис>/data` | Каталог данных (общий volume) |
| `PP_JOB_STORE` | `memory` | `memory` — один процесс; `file` — статусы JSON на общем томе |
| `PP_JOB_TTL_HOURS` | `24` | TTL задач и результатов (file-очередь) |
| `PP_MAX_MB` | `50` | Лимит размера файла |
| `PP_INKSCAPE`, `PP_GHOSTSCRIPT` | авто-поиск | Явные пути к движкам |

В Dockerfile уже заданы `PP_JOB_STORE=file` и `--workers 2`: один инстанс
конвертирует параллельно, статусы всех задач видны из любого процесса
(файловая очередь + общий volume) — этого достаточно для одиночного сервера.

## Горизонтальное масштабирование

Архитектура готова к N воркерам:

1. **Один хост, параллелизм** — уже в Dockerfile: `uvicorn --workers 2`
   (можно поднять до числа ядер минус 1). Статусы — file-очередь на volume.
2. **Несколько реплик/хостов (Docker swarm)** — общий том данных
   (`PP_DATA_DIR`) для всех реплик + `file`-очередь:

   ```bash
   docker stack deploy -c services/converter/docker-compose.yml converter
   docker service scale converter_converter=5
   ```

   Порт наружу публикует ingress-сеть swarm. Требование: общий том
   (NFS/Ceph/…); если общего тома нет — результаты и статусы нужно перенести
   в S3/Redis (слой `jobs.py` и статика `/data` спроектированы так, что
   хранилище подменяется, не трогая API).

Почему так: очередь задач и результаты живут на общем томе, а не в памяти
процесса, поэтому любой воркер отвечает про любую задачу — реплики не нужно
«приклеивать» к задачам.

## Приложение (клиент)

По умолчанию клиент обращается к VPS-серверу `http://193.233.193.12:8120`
(развёрнут в 2026-09). Адрес можно переопределить env `PP_CONVERTER_URL` либо
кнопкой-шестерёнкой на экране «Геометрия». На рабочих ПК Python и движки не
нужны — они обращаются к удалённому серверу:

```bash
set PP_CONVERTER_URL=http://193.233.193.12:8120
```

## Тесты

```bash
python -m pytest tests -q
```

Примечание среды: Ghostscript в песочнице разработки не стартует — тесты
реального EPS-прогона помечены `skipif` по доступности GS.
