FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PORT=8080

WORKDIR /app

# System CA bundle is already at /etc/ssl/certs/ca-certificates.crt in slim image
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

# /app/data is the persistent volume mount point on Fly.io
RUN mkdir -p /app/data

EXPOSE 8080

# Single worker (in-memory tv_session/auth_state must not be split across procs).
# Threaded so concurrent scan sub-requests still work.
CMD ["sh", "-c", "gunicorn --bind 0.0.0.0:${PORT:-8080} --workers 1 --threads 8 --timeout 120 --access-logfile - web:app"]
