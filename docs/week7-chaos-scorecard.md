# Week 7 chaos scorecard

Two scenarios plus one check, run **2026-09-04** against a live cluster.
Predictions were written down before the run and are not edited afterwards.

**Three predictions. Three wrong.**

| | Scenario | Predicted | **Measured** |
|---|---|---|---|
| **1** | Partition one api pod from Postgres | Auto-remediated, 4–6 min | **Auto-remediated — 13m52s, and it nearly didn't fire** |
| **2** | Postgres outage under both api pods | Guard refuses | **Guard failed. Both pods quarantined, zero refusals** |
| **3** | Remediator held down 10 min | Needed a human | **Undetected. Alarm never fired** |

Outcomes: Self-healed · Auto-remediated · Correctly refused · Needed a human ·
**Undetected** — a scenario that reveals a blind spot has succeeded, not failed.

No code or alert rule was changed. The measured behaviour is the artifact; every
fix below is a recommendation. Commands: [`week7-chaos-runbook.md`](week7-chaos-runbook.md).
Manifests: [`../chaos/`](../chaos/).

---

## 1 — Single-pod partition · Auto-remediated

NetworkChaos `partition`, one `railhead-api` pod ↔ `railhead-postgresql-0`, by
pod name, `duration: 15m`. *Analogue: one replica isolated from its database.*

| | |
|---|---|
| Detection | **13m52s** (predicted 4–6 min) |
| Remediation | Quarantined **12s** after FIRING |
| Recovery | Replacement Ready ~30s; Deployment back to 2/2 |
| Blast radius | One pod. Sibling never alerted, never left the EndpointSlice |

```
13:17:38  inject
13:23:17  ratio 0.500  -> PENDING
13:24:50  ratio 0.471  -> PENDING ABANDONED, for:2m timer reset
13:29:27  ratio 0.550  -> PENDING (second attempt)
13:31:30  ratio 0.550  -> FIRING  (13m52s)
13:31:42  quarantined
```

**The alert nearly didn't fire.** `/metrics` is instrumented and the rule excludes
only `handler!="/health"`, so scrape traffic was **~45% of the denominator**:
`/items` 5xx 0.0185/s, `/items` 2xx 0.0407/s, **`/metrics` 2xx 0.0482/s**. With
every `/items` request failing the ceiling is `0.05 / 0.098 ≈ 0.51` against a 0.5
threshold — a **2% margin**. The ratio oscillated **0.471–0.550**, so the first
PENDING was abandoned mid-count.

The delay is not the problem: **on a shorter fault, a tighter scrape interval, or
lower real traffic this alert does not fire at all**, and a pod serving nothing
but errors goes unreported. Fix and full reasoning: gotcha #33.

**Mechanism confirmed as predicted.** Probed failure latency **5.10s / 5.01s /
5.01s** — precisely `connect_timeout=5`. The 5xx come from failed *new*
connections; the original pooled connection blocks in `recv()` until TCP
retransmission gives up. Without `connect_timeout` the pod would hang silently
and never alert.

```
File "/app/main.py", line 103, in create_item
    conn = db_pool.getconn()
psycopg2.OperationalError: connection to server at "railhead-postgresql"
    (172.20.49.228), port 5432 failed: timeout expired
```

`/health` stayed green — it is DB-free, and `maxconn=5` bounds hung threads at 5
against a 40-thread limiter.

**Evidence:** `chaos-scenario1-remediator-slack.png` ·
`chaos-scenario1-failure-mechanism.png` ·
`chaos-scenario1-quarantined-labels.png` · `railhead-alert-rules.png`

---

## 2 — Shared-dependency outage · **Guard failed** ← headline

PodChaos `pod-failure` on `railhead-postgresql-0`, `duration: 10m`.
*Analogue: database backend outage taking every replica down at once.*

Predicted `:no_entry: Refusing to quarantine...`. **Measured: both pods
quarantined 300s apart, zero refusals.**

```
20:20:32  inject
20:21:02  both api pods failing (30s)
20:25:34  ktsv8 PENDING
20:26:39  b6886 PENDING          (+65s -- timers desynchronised)
20:27:42  ktsv8 QUARANTINED      webhook 1, multi_pod=False
20:29:22  ktsv8 alert RESOLVED   (left Service -> unscraped -> stale)
20:31:36  readyReplicas back to 2 (replacement Ready)
20:32:42  b6886 QUARANTINED      webhook 2, multi_pod=False
```

The 300s gap is exactly Alertmanager's `group_interval: 5m`.

**The self-erasing evidence loop.** Quarantining a pod drops it from the Service;
the ServiceMonitor scrapes *through* the Service, so Prometheus stops scraping it
and its alert resolves. When the second pod fires, it genuinely is the only
firing pod — the remediator's own action destroyed the evidence its guard reads.
Two conditions combined: `for: 2m` timers desynchronised by 65s, and the guard
counts only `status == "firing"`, so webhook 2 contained both pods but scored
`multi_pod=False`. Alertmanager grouping worked correctly; two paper reviews
blamed it and both were wrong. Full mechanism: gotcha #32.

**Severity, corrected: not a total outage.** `readyReplicas` never reached 0 —
trace **1,1,1,1,2,2,1,2,2,2** — and `MIN_REMAINING_READY` held at every decision.
Defence in depth held at the last layer. What failed was the layer meant to
prevent churn: two pods quarantined and two replacements spawned during an
outage where every replacement was equally broken.
`MAX_QUARANTINES = 3 / 15min` would have stopped a third.

A code review found the risk; only running it found the cause.

**Evidence:** `chaos-scenario2-grouped-alert.png` ·
`chaos-scenario2-cascade-state.png`

---

## 3 — Meta-monitoring check · **Undetected**

PodChaos `pod-failure` on `railhead-remediator`, `duration: 10m`. Run because the
alarm had only ever fired during teardown, when the CloudWatch agent was itself
being destroyed — a trivial path, not the one it exists for.

| | |
|---|---|
| Predicted | CloudWatch ALARM in ~5–6 min |
| **Measured** | **Alarm never left `OK`** |
| Pod state | `0/1` Ready, zero ready endpoints, `CrashLoopBackOff`, **8 restarts**, **10 minutes** |
| Metric | `service_number_of_running_pods` = **`1.0` every single minute** |

**`service_number_of_running_pods` counts pod phase, not readiness.**
`pod-failure` swaps the image for a pause container, which runs happily, so the
pod stays `Running` and keeps counting as one. The alarm fires only when the pod
is deleted or the metric stops publishing — which is why teardown triggered it
and this did not. A crashloop, deadlock or hung server all present identically.
Fix and the independence tradeoff: gotcha #34.

---

## Screenshots

**Captured (6):** `chaos-scenario1-remediator-slack` ·
`chaos-scenario1-failure-mechanism` · `chaos-scenario1-quarantined-labels` ·
`railhead-alert-rules` · `chaos-scenario2-grouped-alert` ·
`chaos-scenario2-cascade-state`

**Three planned screenshots do not exist. Each absence is a result:**

| Planned | Why |
|---|---|
| `chaos-scenario1-alert-firing` | Alert had resolved before capture; the Slack message proves it fired |
| `chaos-scenario2-multipod-refusal-slack` | **There was no refusal** — scenario 2's finding |
| `chaos-check-remediator-down-alarm` | **The alarm never fired** — the check's finding |

---

## Corrections to the pre-session analysis

**The availability burn-rate alerts fired in 8 minutes**, against a prediction of
45 min – 2 h. Warning fired 13:26, Critical 13:30. Two compounding errors:

- **Wrong threshold.** The analysis used `14.4 × 0.05 = 0.72` — the *latency*
  SLO's 5% budget. Availability has a 1% budget: **0.144** and **0.06**, five
  times more sensitive.
- **Wrong assumption about windows.** `rate(...[6h])` computes over the samples
  that exist, not a nominal 6 hours. The cluster had been rebuilt ~12 minutes
  earlier, so the window held ~12 minutes of data. Measured **0.1422** at 13:26
  against a 0.06 threshold; with a full window it would have been ~0.011.

**Burn-rate alerts are far more sensitive on a freshly rebuilt cluster than their
window lengths imply.** SLO validation shortly after a rebuild measures something
other than steady state.

**`status=~"5xx"` is correct**, despite looking malformed.
`prometheus-fastapi-instrumentator` groups codes into classes and emits
`status="2xx"` / `status="5xx"` literally. Verified during the fault: only those
two values existed.
