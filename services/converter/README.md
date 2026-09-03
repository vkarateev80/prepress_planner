# Сервис конвертации (converter)

FastAPI: AI/CDR/EPS → SVG/PDF. Переиспользует локальные движки
(Inkscape, Ghostscript) — эталон конвейеров `cam_pipeline`.

## API

- `POST /convert` — multipart `file` (`.ai|.cdr|.eps`, ≤ 50 МБ) + `target=svg|pdf`
  → `{"job_id": "…"}`
- `GET /convert/{job_id}` → `{"status": "pending|running|done|error",
  "result_url": "/data/out/<id>/result.<ext>", "error": null|"…"}`
- Результаты — в `data/out/<job_id>/` (статикой на `/data`).

## Пример

```bash
curl -F "file=@fixtures/quadroring.ai" -F "target=svg" http://localhost:8120/convert
curl http://localhost:8120/convert/<job_id>
```

## Запуск

```bash
pip install -r requirements.txt
uvicorn converter_app.main:app --port 8120
```

## Тесты

```bash
python -m pytest tests -q
```

Примечание среды: Ghostscript в этой песочнице не стартует — тесты
реального EPS-прогона помечены `skipif` по доступности GS.

