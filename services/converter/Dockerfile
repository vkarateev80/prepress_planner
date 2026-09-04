# Конвертер AI/CDR/EPS → SVG/PDF (Linux).
#
# Движки ставятся из apt (Inkscape, Ghostscript) — контейнер самодостаточен.
# Данные (входные копии, результаты, статусы file-очереди) — в PP_DATA_DIR,
# который в проде монтируется volume-ом (общим для всех реплик).
FROM python:3.12-slim

# Inkscape + Ghostscript + шрифты (без рекомендованных, чтобы образ был легче).
RUN apt-get update && apt-get install -y --no-install-recommends \
        inkscape \
        ghostscript \
        fonts-dejavu \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /srv/converter
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY converter_app ./converter_app

# Общий том данных; file-очередь позволяет N воркерам видеть чужие задачи.
ENV PP_DATA_DIR=/srv/converter/data \
    PP_JOB_STORE=file \
    PP_JOB_TTL_HOURS=24

RUN mkdir -p "$PP_DATA_DIR/out"

EXPOSE 8120
# Несколько процессов-воркеров = параллельная конвертация на одном хосте;
# при нескольких хостах — общий volume + балансировщик (см. README).
CMD ["uvicorn", "converter_app.main:app", "--host", "0.0.0.0", "--port", "8120", "--workers", "2"]
