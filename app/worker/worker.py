import logging
import os
import random
import string
import time

import requests

API_BASE_URL = os.environ.get("API_BASE_URL", "http://localhost:8000")
INTERVAL_SECONDS = float(os.environ.get("INTERVAL_SECONDS", "10"))

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s worker %(levelname)s %(message)s",
)
log = logging.getLogger("worker")


def random_name() -> str:
    suffix = "".join(random.choices(string.ascii_lowercase, k=6))
    return f"item-{suffix}"


def do_get() -> None:
    resp = requests.get(f"{API_BASE_URL}/items", timeout=5)
    log.info("GET /items -> %s (%d items)", resp.status_code, len(resp.json()))


def do_post() -> None:
    name = random_name()
    resp = requests.post(f"{API_BASE_URL}/items", json={"name": name}, timeout=5)
    log.info("POST /items name=%s -> %s %s", name, resp.status_code, resp.json())


def main() -> None:
    log.info("worker starting, API_BASE_URL=%s, interval=%ss", API_BASE_URL, INTERVAL_SECONDS)
    call_get = True
    while True:
        try:
            if call_get:
                do_get()
            else:
                do_post()
        except requests.RequestException as exc:
            log.warning("request failed: %s", exc)

        call_get = not call_get
        time.sleep(INTERVAL_SECONDS)


if __name__ == "__main__":
    main()
