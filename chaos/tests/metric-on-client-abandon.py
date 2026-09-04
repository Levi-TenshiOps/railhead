r"""Assumption test for scenario 1: does http_requests_total still increment
when the client gives up before the response arrives?

Scenario 1's viability depends on it. The worker calls the API with
timeout=5 (app/worker/worker.py) while the API's own psycopg2
connect_timeout is also 5 (app/api/main.py). Under a partition the API
produces its 500 at roughly the same instant the worker abandons the
request. If an abandoned request is never counted, the alert's numerator
AND denominator both stay flat, no series exists, and the alert cannot fire
no matter how broken the pod is.

This isolates that one question and needs no fault injection: it sends a
request and closes the socket immediately, guaranteeing the client is gone
while the server is still working, then re-reads the counter.

Run it INSIDE an api pod (the image has python; it has no curl):

    Get-Content chaos\tests\metric-on-client-abandon.py |
        kubectl -n railhead exec -i <api-pod> -- python -

Piping avoids passing a multi-line program as a quoted argument, which
PowerShell re-quotes and mangles (known-gotchas #20).

PASS -> the counter moved. Scenario 1's race is harmless; proceed.
FAIL -> the counter did not move. Do NOT run scenario 1 as written; see the
        runbook's mitigations (lower connect_timeout, or raise the worker's
        timeout so the two stop tying).
"""

import socket
import time
import urllib.request

BASE = "http://127.0.0.1:8000"
METRIC = "http_requests_total"


def items_counter():
    """Sum every http_requests_total series for the /items handler."""
    body = urllib.request.urlopen(BASE + "/metrics", timeout=10).read().decode()
    total = 0.0
    for line in body.splitlines():
        if line.startswith(METRIC) and "/items" in line:
            try:
                total += float(line.rsplit(" ", 1)[1])
            except (IndexError, ValueError):
                pass
    return total


def abandon_one_request():
    """Send a request, then close without reading a single byte."""
    s = socket.create_connection(("127.0.0.1", 8000), timeout=5)
    s.sendall(
        b"GET /items HTTP/1.1\r\n"
        b"Host: 127.0.0.1\r\n"
        b"Connection: close\r\n"
        b"\r\n"
    )
    # No recv() at all. The server is still handling this when we vanish.
    s.close()


def main():
    before = items_counter()
    print("counter before      : %.1f" % before)

    for _ in range(5):
        abandon_one_request()
    print("abandoned 5 requests")

    time.sleep(3)  # let the server finish and the middleware record

    after = items_counter()
    print("counter after       : %.1f" % after)
    print("delta               : %.1f" % (after - before))
    print()

    if after > before:
        print("PASS - abandoned requests ARE counted.")
        print("Scenario 1's 5s-vs-5s race does not suppress the metric.")
    else:
        print("FAIL - abandoned requests are NOT counted.")
        print("Scenario 1 cannot fire the alert as written. Apply a mitigation")
        print("from the runbook before injecting the partition.")


if __name__ == "__main__":
    main()
