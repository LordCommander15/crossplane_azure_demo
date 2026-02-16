###############################################################################
# Dockerfile — Global Warning System Dashboard
###############################################################################
FROM mcr.microsoft.com/devcontainers/python:3.12 AS base

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app.py .

EXPOSE 8080

CMD ["gunicorn", "--bind", "0.0.0.0:8080", "--workers", "2", "app:app"]
