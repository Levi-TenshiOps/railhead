# Week 7 chaos scorecard

Two chaos scenarios plus one check, run **2026-09-04** against a live cluster.
Predictions were written down *before* the run and are not edited afterwards —
a surprise is only legible as a finding if there is a prior claim to contradict.

**Three predictions. Three wrong.** That is the result.

| | Scenario | Predicted | **Measured** |
|---|---|---|---|
| **1** | Partition one api pod from Postgres | Auto-remediated, 4–6 min | **Auto-remediated — but 13m52s, and it nearly didn't fire** |
| **2** | Postgres outage under both api pods | Guard refuses | **Guard failed. Both pods quarantined, zero refusals** |
| **3** | Remediator held down 10 min | Needed a human | **Undetected. Alarm never fired** |

`Outcome` values: **Self-healed** · **Auto-remediated** · **Correctly refused** ·
**Needed a human** · **Undetected**. The last is a first-class result — a
scenario that reveals a blind spot has succeeded, not failed.

---

## 1 — Single-pod partition · Auto-remediated

NetworkChaos `partition`, one `railhead-api` pod ↔ `railhead-postgresql-0`,
targeted by pod name, `duration: 15m`.
*Analogue: network partition isolating one replica from its database.*

| | |
|---|---|
| Detection | `RailheadAPIPodErrorRate` FIRING at **13m52s** (predicted 4–6 min) |
| Remediation | Quarantined **12s** after FIRING |
| Recovery | Replacement Ready ~30s; Deployment back to 2/2 |
| Blast radius | Exactly one pod. Sibling never alerted, never left the EndpointSlice |
| Outcome | **Auto-remediated** ✅ |

```
13:17:38  inject
13:23:17  ratio 0.500  -> PENDING
13:24:50  ratio 0.471  -> PENDING ABANDONED, for:2m timer reset
13:29:27  ratio 0.550  -> PENDING  (second attempt)
13:31:30  ratio 0.550  -> FIRING   (13m52s)
13:31:42  quarantined
```

**Why it was slow, and why that's not the point.** The alert's denominator
excludes `handler!="/health"` and nothing else — but `/metrics` is instrumented
by the same middleware, and Prometheus scrapes it at roughly the rate the worker
generates real traffic. Measured, scrape traffic was **~45% of the denominator**:

| handler | status | rate/s |
|---|---|---|
| `/items` | 5xx | 0.0185 |
| `/items` | 2xx | 0.0407 |
| **`/metrics`** | **2xx** | **0.0482** |

With every `/items` request failing, the ceiling is
`0.05 / (0.05 + 0.048) ≈ 0.51` against a `0.5` threshold — a **2% margin**. The
ratio oscillated between **0.471 and 0.550**, so the first PENDING period was
abandoned mid-count and the `for: 2m` timer restarted.

**The significance is not the delay. It is that this alert can fail to fire at
all** on a shorter fault, a tighter scrape interval, or lower real traffic. The
pod would serve nothing but errors and nothing would say so.

Same shape as gotcha #24, one layer down: `/health` was recognised as
non-representative traffic and excluded; `/metrics` is equally
non-representative and was not. **Recommended fix:** `handler!~"/health|/metrics"`
in all five rules. Not applied — see gotcha #33.

**Mechanism confirmed exactly as predicted.** Probed failure latency was
**5.10s / 5.01s / 5.01s** — precisely `connect_timeout=5`. The 5xx come from
failed **new** connections, not from the original pooled one, which blocks in
`recv()` until TCP retransmission gives up. `connect_timeout=5` was load-bearing:
without it the pod would hang silently and never alert.

```
File "/app/main.py", line 103, in create_item
    conn = db_pool.getconn()
psycopg2.OperationalError: connection to server at "railhead-postgresql"
    (172.20.49.228), port 5432 failed: timeout expired
```

`/health` stayed green throughout, as predicted — it is DB-free, and the pool's
`maxconn=5` structurally bounds hung threads at 5 against a 40-thread limiter.

**Evidence:** `chaos-scenario1-remediator-slack.png` ·
`chaos-scenario1-failure-mechanism.png` ·
`chaos-scenario1-quarantined-labels.png` · `railhead-alert-rules.png`

---

## 2 — Shared-dependency outage · **Guard failed** ← headline

PodChaos `pod-failure` on `railhead-postgresql-0`, `duration: 10m`.
*Analogue: database backend outage taking every replica down at once.*

| | |
|---|---|
| Predicted | `:no_entry: Refusing to quarantine...` — the `multi_pod` guard holds |
| **Measured** | **Both pods quarantined, 300s apart. Zero refusals.** |
| Severity | **Not a total outage** — see below |
| Outcome | **Auto-remediated, wrongly** |

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

The gap is **exactly 300s = Alertmanager's `group_interval: 5m`**.

**Alertmanager grouping worked correctly.** Both paper reviews predicted this
failure and both blamed grouping — both were wrong. `slack_configs` and
`webhook_configs` sit on the same receiver, so Slack and the remediator get
identical payloads, and the grouped Slack message showing both pods *is* the
second webhook.

**The self-erasing evidence loop.** Quarantining pod A rewrites its `app` label,
dropping it from the Service. The ServiceMonitor scrapes through the Service, so
Prometheus stops scraping A, its series goes stale, and **A's alert resolves**.
When B fires, B genuinely *is* the only firing pod.

Two things were required, and the guard needed only one to fail:

1. **`for: 2m` timers desynchronise.** A simultaneous fault does not produce
   simultaneous alerts — the two ratios crossed 0.5 about 65s apart, amplified
   by the same `/metrics` dilution from scenario 1. Prometheus never sends a
   `pending` alert, so webhook 1 legitimately carried one pod.
2. **The `status == "firing"` filter.** Webhook 2 *did* contain both pods
   (`send_resolved = true`), but the guard counts only firing alerts, so the
   resolved pod contributed nothing.

**Severity, corrected.** This was **not** a total outage. `readyReplicas` never
reached 0 — observed trace **1,1,1,1,2,2,1,2,2,2** — and `MIN_REMAINING_READY`
held at every decision. Defence-in-depth held at the last layer. What failed was
the layer meant to prevent pointless churn: two pods quarantined and two
replacements spawned during an incident where every replacement was equally
broken. `MAX_QUARANTINES = 3 / 15min` would have stopped a third.

**Why this is the argument for chaos engineering.** A code review found the
risk. Only running it found the cause — an interaction between the remediator,
the Service selector, the ServiceMonitor and Prometheus staleness, visible in no
single file.

**Recommended fixes** (none applied): count pods from the alert *group* rather
than firing-only; or gate on Deployment-level unavailable replicas; or add a
cooldown between quarantines. Fixing the `/metrics` denominator also reduces the
ratio noise that desynchronised the timers. See gotcha #32.

**Evidence:** `chaos-scenario2-grouped-alert.png` ·
`chaos-scenario2-cascade-state.png`

---

## 3 — Meta-monitoring check · **Undetected**

PodChaos `pod-failure` on `railhead-remediator`, `duration: 10m`. Run because
the alarm had only ever been seen firing during teardown, when the CloudWatch
agent was itself being destroyed — a trivial path, not the one it exists for.

| | |
|---|---|
| Predicted | CloudWatch ALARM in ~5–6 min |
| **Measured** | **Alarm never left `OK`** |
| Pod state | `0/1` Ready, **zero ready endpoints**, `CrashLoopBackOff`, **8 restarts**, for **10 minutes** |
| Metric | `service_number_of_running_pods` = **`1.0` every single minute** |
| Outcome | **Undetected** |

**`service_number_of_running_pods` counts pod PHASE, not readiness.**
`pod-failure` swaps the container image for a pause image; a pause container
runs happily, so the pod stays `Running` and keeps counting as one.

The alarm therefore fires only when the pod is **deleted** or the metric **stops
publishing** — which is exactly why it fired at teardown, and why that
observation proved less than it appeared to. The blind spot is wider than the
injected fault: a crashloop, a deadlock, or a hung HTTP server all present
identically as `Running`-but-not-`Ready`, and those are the realistic failures.

**Recommended fix:** an external synthetic probe against `/healthz`. A
readiness-derived Prometheus metric would be accurate but reintroduces the
in-cluster dependency the alarm exists to avoid. The tension is real: the alarm
is coarse *because* it is independent. See gotcha #34.

---

## Screenshots

**Captured (6):** `chaos-scenario1-remediator-slack` ·
`chaos-scenario1-failure-mechanism` · `chaos-scenario1-quarantined-labels` ·
`railhead-alert-rules` · `chaos-scenario2-grouped-alert` ·
`chaos-scenario2-cascade-state`

**Three planned screenshots do not exist. Each absence is a result, not a gap:**

| Planned | Why it does not exist |
|---|---|
| `chaos-scenario1-alert-firing` | The alert had already resolved before capture. The Slack message proves it fired; re-triggering was not worth a second 14-minute run |
| `chaos-scenario2-multipod-refusal-slack` | **There was no refusal.** The guard never engaged — that is scenario 2's finding |
| `chaos-check-remediator-down-alarm` | **The alarm never fired.** That is the check's finding |

---

## Corrections to the pre-session analysis

Recorded because the analysis was confident and wrong, and the errors are
instructive.

**The availability burn-rate alerts fired in 8 minutes**, against a prediction
that burn-rate alerts would need 45 min – 2 h of sustained injection.
`RailheadAPIAvailabilityBurnRateWarning` fired at 13:26,
`...Critical` at 13:30. Two compounding errors:

- **Wrong threshold.** The analysis reasoned about `14.4 × 0.05 = 0.72` — the
  *latency* SLO's 5% budget. The *availability* SLO has a 1% budget, giving
  **0.144** and **0.06**: five times more sensitive.
- **Wrong assumption about windows.** `rate(...[6h])` computes over the samples
  that exist, not a nominal 6 hours. The cluster had been rebuilt ~12 minutes
  earlier, so the 6h window held ~12 minutes of data. Measured **0.1422** at
  13:26 against a 0.06 threshold; with a genuinely full window it would have
  been ~0.011.

Generalisable: **burn-rate alerts are far more sensitive on a freshly rebuilt
cluster than their window lengths imply.** SLO validation shortly after a
rebuild measures something other than steady state.

**`status=~"5xx"` is correct**, despite looking like a malformed regex.
`prometheus-fastapi-instrumentator` groups codes into classes and emits
`status="2xx"` / `status="5xx"` literally. Verified during the fault: only those
two values existed. No action needed.

---

**No code or alert rule was changed.** The measured behaviour is the artifact;
every fix above stays a recommendation. Execution steps are in
[`week7-chaos-runbook.md`](week7-chaos-runbook.md); manifests in
[`../chaos/`](../chaos/).
