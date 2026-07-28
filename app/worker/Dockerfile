FROM python:3.12-slim AS builder

WORKDIR /app
ENV PIP_NO_CACHE_DIR=1

COPY requirements.txt .
RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"
RUN pip install -r requirements.txt

FROM python:3.12-slim

WORKDIR /app
COPY --from=builder /opt/venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

COPY worker.py .

# Runs as an unprivileged user. It only makes outbound HTTP calls and binds
# no port at all, so there is nothing here that root is required for.
RUN useradd --system --uid 1000 --no-create-home app
USER app

CMD ["python", "worker.py"]
