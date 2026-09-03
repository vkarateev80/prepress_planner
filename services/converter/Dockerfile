FROM python:3.12-slim

WORKDIR /srv/converter
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Движки конвертации (в проде монтируются volume-ом).
ENV PP_INKSCAPE=/engines/inkscape/bin/inkscape
ENV PP_GHOSTSCRIPT=/engines/ghostscript/bin/gswin64c

COPY converter_app ./converter_app
RUN mkdir -p data/out

EXPOSE 8120
CMD ["uvicorn", "converter_app.main:app", "--host", "0.0.0.0", "--port", "8120"]
