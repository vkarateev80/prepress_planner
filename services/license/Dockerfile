FROM python:3.12-slim

WORKDIR /srv/license
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY license_app ./license_app

EXPOSE 8121
CMD ["uvicorn", "license_app.main:app", "--host", "0.0.0.0", "--port", "8121"]
