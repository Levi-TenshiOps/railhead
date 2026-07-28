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

COPY remediate.py .

# Runs as an unprivileged user. Nothing here needs root: the Kubernetes API
# calls authenticate with the ServiceAccount token, not the container user,
# so dropping privileges costs nothing and removes the container itself as a
# useful foothold if the webhook is ever reachable by something unexpected.
RUN useradd --system --uid 1000 --no-create-home app
USER app

EXPOSE 8080
CMD ["python", "remediate.py"]
