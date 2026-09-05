# Evidence: pod-error-rate trigger validation

Record of a deliberate test: one `railhead-api` pod's `/etc/hosts` was edited to break
its Postgres DNS resolution, and its existing Postgres connections were terminated via
`pg_terminate_backend()`, to confirm this combination reliably produces 5xx on `/items`
while `/health` keeps passing — the exact condition `remediate.py` relies on.

| Step | Expected | Result |
|---|---|---|
| Baseline: `/items`/`/health` 200 | 200 | PASS |
| Corrupt TARGET's `/etc/hosts` | resolves to `127.0.0.1` | PASS |
| `/items` immediately after | still 200 (cached conn) | PASS |
| Terminate TARGET's DB connections | 0 remain after | PASS |
| `/items` × 5 after termination | 500, no hang | PASS |
| Readiness (`/health`, pod status) | stays green throughout | PASS |
| CONTROL pod | unaffected (200) | PASS |
| TARGET in EndpointSlice | still present | PASS |

Revert confirmed clean: `/items` returns 200 again once `/etc/hosts` is fixed, zero pod
restarts across the whole test.
