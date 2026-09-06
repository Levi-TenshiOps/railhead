# Week 7 chaos scorecard

Two scenarios plus one check, run **2026-09-04** against a live cluster, with
scenario 1 re-run **2026-09-05** after a fix. Predictions were written down before each run
and are not edited afterwards. **All timestamps are UTC**, matching what Prometheus
and the container logs record.

**A third scenario was planned and dropped.** Storage latency, modelled on vSAN
incidents, needed IOChaos — which depends on FUSE, and `/dev/fuse` cannot be
granted on these cgroup v2 nodes. Dropped on a measured constraint before a
session went into it, rather than during one ([`known-gotchas.md`](known-gotchas.md) #30).

**Reading the code found the risk; only running it found the cause.** Two
independent design reviews ran against the remediator beforehand; both predicted
scenario 2 would fail, and **both named the wrong mechanism**, blaming
Alertmanager's grouping — which worked correctly throughout. A defect whose cause
two careful reviews get wrong is one only a live run will explain.

| | Scenario | Predicted | **Measured** |
|---|---|---|---|
| **1** | Partition one api pod from Postgres | Auto-remediated, 4–6 min | **Auto-remediated — 13m52s, and it nearly didn't fire.** Fixed and re-run: **5m46s** |
| **2** | Postgres outage under both api pods | Guard refuses | **Guard did not engage. Both pods quarantined, zero refusals — but no outage** |
| **3** | Remediator held down 10 min | Needed a human | **Undetected. Alarm never fired** |

Outcomes: Self-healed · Auto-remediated · Correctly refused · Needed a human ·
**Undetected** — a scenario that reveals a blind spot has succeeded, not failed.

**No code was changed, and the measured behaviour is the artifact** — the findings
below are recorded as they happened, not patched away. One exception, made
deliberately: the `/metrics` denominator defect in scenario 1 was fixed and that
re-run to measure it, because it is a matcher change that can only narrow what the
rule counts. The before and after are both kept. Everything else stays a
recommendation. Commands: [`week7-chaos-runbook.md`](week7-chaos-runbook.md).
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

**The alert nearly didn't fire.** `/metrics` is instrumented and at the time the
rule excluded only `handler!="/health"`, so scrape traffic was **~45% of the
denominator**:
`/items` 5xx 0.0185/s, `/items` 2xx 0.0407/s, **`/metrics` 2xx 0.0482/s**. With
every `/items` request failing the ceiling is `0.05 / 0.098 ≈ 0.51` against a 0.5
threshold — a **2% margin**. The ratio oscillated **0.438–0.550**, so the first
PENDING was abandoned mid-count.

The delay is not the problem: **on a shorter fault, a tighter scrape interval, or
lower real traffic this alert does not fire at all**, and a pod serving nothing
but errors goes unreported. Fix and full reasoning: gotcha #33.

**Mechanism confirmed as predicted.** Every failing request took almost exactly
5 seconds. Mean `/items` duration on the partitioned pod was **5.006s** for nine
minutes straight; its healthy sibling served the same endpoint in **0.005s**.
That 5-second wall is `connect_timeout=5`.

So the 5xx came from *new* connections timing out, not from the pooled one. The
pooled connection just blocks in `recv()` until TCP gives up. Without
`connect_timeout` the pod would hang silently and never alert at all.

The histogram could not show this on its own — its buckets stop at 1 second, so
every failure landed in `+Inf`. The 5.006s came from `_sum / _count` instead.

```
File "/app/main.py", line 103, in create_item
    conn = db_pool.getconn()
psycopg2.OperationalError: connection to server at "railhead-postgresql"
    (172.20.49.228), port 5432 failed: timeout expired
```

`/health` stayed green — it is DB-free, and `maxconn=5` bounds hung threads at 5
against a 40-thread limiter.

**Evidence:** `chaos-scenario1-remediator-slack.png` ·
`chaos-scenario1-failure-mechanism.png` · `chaos-scenario1-quarantined-labels.png`

There is deliberately **no screenshot of the pre-fix rules** — `railhead-alert-rules.png`
was re-captured after the fix and now shows the current expressions. The pre-fix
matcher is quoted above and preserved in git history; a stale screenshot kept only
to illustrate a superseded state is a thing that rots.

### The fix, applied and re-measured 2026-09-05

`handler!="/health"` became `handler!~"/health|/metrics"` in all five rules
([`terraform/modules/argocd/main.tf`](../terraform/modules/argocd/main.tf) — note
the operator change, `!~` not `!=`, because the exclusion is now an alternation).
The scenario was re-run unchanged: same manifest, same pod-name targeting, same
procedure, no `/metrics` polling.

| | Before | **After** |
|---|---|---|
| PENDING | 5m39s | **3m46s** |
| PENDING abandoned | **yes, once** | **none** |
| FIRING | **13m52s** | **5m46s** |
| Quarantine | 12s after FIRING | 30s after FIRING |
| Ratio behaviour | oscillated 0.438–0.550 | climbed monotonically to **1.0000** |
| Margin over the 0.5 threshold | **2%** | **100%** |

```
13:56:56  inject
14:00:42  ratio crosses 0.5  -> PENDING
14:01:50  ratio 1.0000       (5m window now holds only fault samples)
14:02:42  FIRING             (5m46s)
14:03:12  quarantined; replacement Ready, Deployment back to 2/2
```

**Detection went from 13m52s to 5m46s — 8m06s faster.** The speed is the smaller
half of it. Removing `/metrics` makes the ratio **independent of throughput**:
with only `/items` in the denominator, a pod failing every request reads 1.0 no
matter how far its throughput has collapsed. The old rule's *ceiling* of 0.5102 is
roughly the value the new rule merely passes through at ~3m30s on the way up.

Measured on the target pod before injection: `/metrics` was a **fixed 0.03333/s**
— one scrape per 30s, identical on both pods, independent of load — against
`/items` at 0.04444/s, so **42.9%** of the old denominator. A constant term in a
denominator whose other term collapses under fault dilutes worst exactly when
detection matters most.

**Comparability, stated plainly.** The baseline ran on a cluster rebuilt 12
minutes earlier; this run on one up 24 hours. Pre-fault `/metrics` share was 42.9%
against the baseline's ~45% measured mid-fault — the same regime, so the numbers
are comparable, but this is not a controlled A/B and shouldn't be read as one.

This is the one recommendation from Week 7 that was implemented rather than left
on record, because it is a matcher change with no behavioural risk: it narrows
what the rule counts and cannot make the alert fire on anything it didn't before.
The guard defect in scenario 2 stays unfixed on purpose.

**Evidence:** `railhead-alert-rules.png` — all five rules across all three groups
carrying `handler!~"/health|/metrics"`, verified loaded in Prometheus with group
health `ok`. Note the operator: `!~`, not `!=`. A malformed regex here makes
Prometheus reject the whole group and leaves **no** per-pod alert at all, which is
worse than a slow one — so the change was gated on reading it back from
`/api/v1/rules` rather than on `terraform apply` reporting success.

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

**Severity, corrected: not a total outage.** Queried from
`kube_deployment_status_replicas_ready`, `readyReplicas` was 2 until 20:28:08,
**1** for seven consecutive 30s scrapes (20:28:08–20:31:08), and back to 2 from
20:31:38 — a single dip of about three minutes, and **never 0**. Both webhooks
arrived while it read 2, so `ready - 1 >= MIN_REMAINING_READY` **passed** each
time: the guard permitted both quarantines rather than blocking either. The floor
was there and was never reached. What failed was the layer meant to prevent
churn: two pods quarantined and two replacements spawned during an outage where
every replacement was equally broken. `MAX_QUARANTINES = 3 / 15min` would have
stopped a third — reasoning, not a measurement; no third alert arrived.

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
`chaos-scenario2-grouped-alert` · `chaos-scenario2-cascade-state` ·
`railhead-alert-rules` (**re-captured 2026-09-05** after the scenario 1 fix — it shows the
rules as they stand now, not as they were during the 13m52s run)

**Three planned captures were never taken, and two of those absences are
themselves results:**

- **No alert-in-FIRING screenshot.** It had resolved before one could be taken.
  The Slack message is the record that it fired.
- **No refusal screenshot — because no refusal happened.** That is scenario 2's
  finding.
- **No alarm screenshot — because the alarm never fired.** That is the
  meta-monitoring check's finding.

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
