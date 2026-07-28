import os
from contextlib import asynccontextmanager
from datetime import datetime

from fastapi import FastAPI, HTTPException
from prometheus_fastapi_instrumentator import Instrumentator
from prometheus_fastapi_instrumentator.metrics import default as default_metrics
from psycopg2 import pool
from pydantic import BaseModel

DB_HOST = os.environ.get("DB_HOST", "localhost")
DB_PORT = os.environ.get("DB_PORT", "5432")
DB_NAME = os.environ.get("DB_NAME", "railhead")
DB_USER = os.environ.get("DB_USER", "railhead")
DB_PASSWORD = os.environ.get("DB_PASSWORD", "")

db_pool: pool.SimpleConnectionPool | None = None


@asynccontextmanager
async def lifespan(app: FastAPI):
    global db_pool
    db_pool = pool.SimpleConnectionPool(
        1,
        5,
        host=DB_HOST,
        port=DB_PORT,
        dbname=DB_NAME,
        user=DB_USER,
        password=DB_PASSWORD,
        connect_timeout=5,
    )
    conn = db_pool.getconn()
    try:
        with conn.cursor() as cur:
            cur.execute(
                """
                CREATE TABLE IF NOT EXISTS items (
                    id SERIAL PRIMARY KEY,
                    name TEXT NOT NULL,
                    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
                )
                """
            )
        conn.commit()
    finally:
        db_pool.putconn(conn)

    yield

    db_pool.closeall()


app = FastAPI(title="railhead-api", lifespan=lifespan)

# .instrument() attaches middleware that times/counts every request as it
# flows through; .expose() adds the GET /metrics route Prometheus scrapes.
# Calling .instrument() with no prior .add() implicitly registers this same
# default() metric bundle (request count, latency histograms, in-progress
# gauge) with ITS OWN default buckets -- adding it explicitly here changes
# nothing except the bucket boundaries. latency_lowr_buckets is overridden
# to add a 0.3s (300ms) boundary: the library's own default (0.1, 0.5, 1)
# has nothing at 300ms, and a burn-rate SLO needs a real bucket boundary at
# its threshold -- histogram_quantile() can interpolate a percentile, but a
# bucket-ratio burn-rate calculation can't interpolate an arbitrary cutoff.
instrumentator = Instrumentator()
instrumentator.add(default_metrics(latency_lowr_buckets=(0.1, 0.3, 0.5, 1)))
instrumentator.instrument(app).expose(app)


class Item(BaseModel):
    id: int
    name: str
    created_at: datetime


class ItemCreate(BaseModel):
    name: str


@app.get("/health")
def health():
    return {"status": "ok"}


# Deliberately no try/except around the database calls below. A failed query
# must surface as a 500: that is the signal the availability SLO measures and
# the per-pod error-rate alert fires on, and it is what tells the remediator
# which pod to quarantine. Catching it here to return a friendlier response
# would hide exactly the failure this system is built to detect.
@app.get("/items", response_model=list[Item])
def list_items():
    conn = db_pool.getconn()
    try:
        with conn.cursor() as cur:
            cur.execute("SELECT id, name, created_at FROM items ORDER BY id DESC")
            rows = cur.fetchall()
        return [{"id": r[0], "name": r[1], "created_at": r[2]} for r in rows]
    finally:
        db_pool.putconn(conn)


@app.post("/items", response_model=Item, status_code=201)
def create_item(item: ItemCreate):
    if not item.name.strip():
        raise HTTPException(status_code=422, detail="name must not be empty")

    conn = db_pool.getconn()
    try:
        with conn.cursor() as cur:
            cur.execute(
                "INSERT INTO items (name) VALUES (%s) RETURNING id, name, created_at",
                (item.name.strip(),),
            )
            row = cur.fetchone()
        conn.commit()
        return {"id": row[0], "name": row[1], "created_at": row[2]}
    finally:
        db_pool.putconn(conn)
