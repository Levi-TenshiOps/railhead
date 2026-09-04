# Week 7 chaos scorecard

For each injected failure: did it self-heal, was it caught by the Week 6
auto-remediation, or did it need a human?

**Predictions were written before the first run and have not been edited since.**
That is the point of recording them: a surprise is only legible as a finding if
there is a prior claim to contradict. Measured values were filled in during
execution on **2026-09-04**; where a measurement contradicts a prediction, the
prediction stays and the difference is written up under Findings.

`Outcome` is one of:

| Value | Meaning |
|---|---|
| **Self-healed** | Recovered with no intervention and no remediator action |
| **Auto-remediated** | The remediator acted, correctly |
| **Correctly refused** | The remediator declined to act, and declining was right |
| **Needed a human** | Manual intervention required |
| **Undetected** | Nothing noticed. A blind spot, and a valid result |

---

## Summary

| Scenario | Predicted outcome | **Measured outcome** |
|---|---|---|
| 1 — Single-pod partition | Auto-remediated | **Auto-remediated** (but 2.3x slower than predicted) |
| 2 — Shared-dependency outage | Correctly refused | **Auto-remediated — WRONGLY. Zero refusals.** |
| Check — Remediator down | Needed a human | **Undetected** |

---

## Scenario 1 — Single-pod partition from Postgres

| Field | Value |
|---|---|
| **Fault** | NetworkChaos `partition`, `direction: both`, one `railhead-api` pod ↔ `railhead-postgresql-0`, targeted by pod name, `duration: 15m` |
| **Real-world analogue** | Network partition between an application instance and its database backend — one replica isolated while its peers stay healthy |
| **What it tests** | The remediator against a fault it was never tuned for |
| **Predicted detection** | `RailheadAPIPodErrorRate`, PENDING ~2–3 min, FIRING ~4–6 min |
| **Predicted outcome** | **Auto-remediated** |
| **Measured detection** | `RailheadAPIPodErrorRate` FIRING — **13m 52s** after injection |
| **Measured outcome** | **Auto-remediated** ✅ |
| **Measured time to remediate** | 12 seconds after FIRING (13:31:30 → 13:31:42) |
| **Measured time to recover** | Replacement Ready in ~30s; Deployment back to 2/2 |
| **Blast radius** | Exactly one pod. Sibling never left the EndpointSlice, never alerted |
| **Evidence** | `chaos-scenario1-remediator-slack.png`, `chaos-scenario1-failure-mechanism.png`, `chaos-scenario1-quarantined-labels.png`, `railhead-alert-rules.png` |
| **Cleanup verified** | CR auto-recovered at `duration`, then deleted; quarantined pod removed; 2/2 restored |

### Timeline

```
13:17:38  inject
13:23:17  ratio 0.500  -> PENDING           (first attempt)
13:24:50  ratio 0.471  -> PENDING ABANDONED, for:2m timer reset
13:29:27  ratio 0.550  -> PENDING           (second attempt)
13:31:30  ratio 0.550  -> FIRING            (13m52s after inject)
13:31:42  quarantined
```

### Findings

**1. Detection took 13m52s against a predicted 4–6 min — and the delay is not
the important part.** The per-pod error ratio oscillated between **0.471 and
0.550**, straddling the 0.5 threshold, so the first PENDING period was abandoned
mid-count and the `for: 2m` timer restarted. The alert needed two attempts.

**2. Root cause: `/metrics` is in the alert's denominator.** The rule excludes
only `handler!="/health"`. Prometheus scrapes `/metrics` at roughly the same
rate the worker generates real traffic, so scrape traffic was **~45% of the
denominator**:

| handler | status | rate/s |
|---|---|---|
| `/items` | 5xx | 0.0185 |
| `/items` | 2xx | 0.0407 |
| **`/metrics`** | **2xx** | **0.0482** |

With every `/items` request failing, the ceiling is roughly
`0.05 / (0.05 + 0.048) ≈ 0.51` — a 2% margin over the threshold.
**The significance is not the delay: it is that this alert can fail to fire at
all on a shorter fault, or with a slightly faster scrape interval.**

This is gotcha #24's pattern one layer down — `/health` was recognised as
non-representative traffic and excluded; `/metrics` is equally
non-representative and was not.

**Recommended fix (NOT applied — measured behaviour is the artifact):** change
the exclusion to `handler!~"/health|/metrics"` in all five rules.

**3. The failure mechanism was confirmed exactly as predicted.** Probed latency
was **5.10s / 5.01s / 5.01s** — precisely `connect_timeout=5` — and the
remediator's own evidence block captured the stack:

```
File "/app/main.py", line 103, in create_item
    conn = db_pool.getconn()
File ".../psycopg2/pool.py", line 93, in _getconn
    return self._connect(key)
psycopg2.OperationalError: connection to server at "railhead-postgresql"
    (172.20.49.228), port 5432 failed: timeout expired
```

The 5xx come from **failed new connections**, not from the hung original one,
which blocks in `recv()` until TCP retransmission gives up. `connect_timeout=5`
was load-bearing: without it the pod would hang silently and never alert.

**4. `/health` stayed green throughout**, as predicted. The pool's `maxconn=5`
structurally bounds hung threads at 5 against a 40-thread anyio limiter, so
readiness cannot be starved by this fault at any traffic rate.

**5. `status` label values are classes, not codes.** `status=~"5xx"` looks like
a malformed regex but is correct: `prometheus-fastapi-instrumentator` groups
codes into classes and emits `status="2xx"` / `status="5xx"` literally.
Verified during the fault: only `2xx` and `5xx` series existed. No action needed.

**6. The availability burn-rate alerts fired, contradicting the pre-session
analysis.** `RailheadAPIAvailabilityBurnRateWarning` fired at 13:26 (8 min in)
and `...Critical` at 13:30. The pre-session review claimed burn-rate alerts
would need 45 min – 2 h of sustained injection. That was wrong twice:

- **Wrong threshold.** The review reasoned about `14.4 × 0.05 = 0.72`, which is
  the *latency* SLO's 5% budget. The *availability* SLO has a 1% budget, giving
  thresholds of **0.144** and **0.06** — 5x more sensitive.
- **Wrong assumption about window contents.** `rate(...[6h])` computes over the
  samples that exist, not over a nominal 6 hours. The cluster had been rebuilt
  ~12 minutes earlier, so the 6h window held ~12 minutes of data. Measured
  value at 13:26 was **0.1422** against a 0.06 threshold; with a genuinely full
  6h window it would have been ~0.011.

Generalisable: **burn-rate alerts are dramatically more sensitive on a freshly
rebuilt cluster than their window lengths imply.** Any SLO validation done
shortly after a rebuild is measuring something other than steady-state.

---

## Scenario 2 — Shared-dependency outage — **HEADLINE FINDING**

| Field | Value |
|---|---|
| **Fault** | PodChaos `pod-failure` on `railhead-postgresql-0`, `duration: 10m` |
| **Real-world analogue** | Storage/database backend outage taking every application replica down at once |
| **What it tests** | The `multi_pod` guard, and the Alertmanager `group_by` assumption it depends on |
| **Predicted detection** | FIRING for **both** pods, ~4–6 min |
| **Predicted outcome** | **Correctly refused** |
| **Predicted Slack** | `:no_entry: Refusing to quarantine <pod>: multiple pods are alerting` |
| **Measured detection** | FIRING for both pods, but **at different times** — 20:27:44 and ~20:28:49 |
| **Measured outcome** | **Auto-remediated — WRONGLY. Both pods quarantined, 5 minutes apart, ZERO refusals.** |
| **Measured recovery** | Postgres `1/1` ~60s after CR recovery; service self-recovered to 2/2 |
| **Evidence** | `chaos-scenario2-grouped-alert.png`, `chaos-scenario2-cascade-state.png` |
| **Cleanup verified** | CR deleted, both quarantined pods deleted, 2/2 restored, Postgres `1/1` |

**The predicted `chaos-scenario2-multipod-refusal-slack.png` does not exist,
because there was no refusal. That absence is the result, not a missing
artifact.**

### Timeline

```
20:20:32  inject PodChaos on railhead-postgresql-0
20:21:02  worker begins failing            (30s: Bitnami readiness failureThreshold=6)
20:25:34  ktsv8 PENDING
20:26:39  b6886 PENDING                    (+65s -- for:2m timers desynchronised)
20:27:42  ktsv8 QUARANTINED                webhook 1, multi_pod=False
20:28:49  both briefly FIRING
20:29:22  ktsv8 alert RESOLVED             (left Service -> unscraped -> series stale)
20:31:36  ready=2                          (replacement 8xs6m becomes Ready)
20:32:42  b6886 QUARANTINED                webhook 2, multi_pod=False
```

Gap between quarantines: **exactly 300s = Alertmanager's `group_interval: 5m`.**

### Payload contents, established from measurement

`slack_configs` and `webhook_configs` are on the **same receiver**, so Slack and
the remediator receive **identical payloads**. Prometheus alert state at each
delivery instant:

| Delivery | Alert states | `multi_pod` |
|---|---|---|
| 1 @ 20:27:42 | `ktsv8=firing`, **`b6886=pending`** | False — pending alerts are never sent to Alertmanager, so the payload carried only ktsv8 |
| 2 @ 20:32:42 | `b6886=firing`, `ktsv8` no longer firing | False — payload contained **both** pods (`send_resolved = true`), but the guard filters to `status == "firing"` before counting |

**The grouped Slack screenshot showing both pods and the `multi_pod=False`
evaluation are the same delivery.** They are not contradictory: the guard
counted one because the other was resolved.

### Mechanism: a self-erasing evidence loop

Quarantining pod A rewrites its `app` label, removing it from the Service. The
ServiceMonitor scrapes via the Service, so Prometheus stops scraping A, A's
series goes stale, and **A's alert resolves.** When B subsequently fires, B
genuinely *is* the only firing pod.

**The remediator's own action destroys the evidence its guard depends on.** The
guard is structurally unable to observe two simultaneously-broken pods once it
has acted on the first.

The `ready_replicas` backstop was then defeated by the ReplicaSet working
correctly: the replacement for A reached Ready at 20:31:36, restoring
`ready=2`, which satisfied `ready - 1 >= MIN_REMAINING_READY` and licensed the
second quarantine.

Two independent contributors, both required:
1. **`for: 2m` desynchronisation.** A genuinely simultaneous fault does not
   produce simultaneous alerts. The two pods' ratios crossed 0.5 ~65s apart —
   amplified by the `/metrics` dilution from scenario 1 making the ratio
   marginal and noisy.
2. **The `status == "firing"` filter.** Even when both pods appear in one
   payload, a resolved pod is not counted.

### Severity — corrected

**This was NOT a total outage.** `readyReplicas` never reached 0 (observed
trace: 1,1,1,1,2,2,1,2,2,2). `MIN_REMAINING_READY` held at every decision.
Defence-in-depth held at the last layer; the layer that failed was the one meant
to prevent pointless churn during a shared outage.

**Net effect:** 2 pods quarantined and 2 replacements spawned during an incident
where every replacement was equally broken — exactly what the `multi_pod` guard
exists to prevent. `MAX_QUARANTINES = 3 / 15min` would have stopped a third.

### Why this is the argument for chaos engineering

Two paper reviews predicted this failure. Both got the **mechanism** wrong: they
blamed Alertmanager grouping, and grouping worked correctly. The real cause —
that the remediator's own remediation erases the signal its guard reads — is not
visible in a code review, because it is an interaction between the remediator,
the Service selector, the ServiceMonitor, and Prometheus staleness.

**A code-level review found the risk. Only running it found the cause.**

### Recommended fixes (NOT applied)

1. Count pods from the alert *group*, not from firing-only: include
   `status == "resolved"` alerts whose pod carries a `quarantined-at` label.
2. Or gate on Deployment-level health: refuse if the Deployment's unavailable
   replica count indicates a shared fault rather than one bad pod.
3. Or add a cooldown: refuse any quarantine within N minutes of the previous
   one unless the previous pod recovered.
4. Fixing the `/metrics` denominator (scenario 1) also reduces the ratio noise
   that desynchronised the timers.

---

## Check — CloudWatch meta-monitoring — **UNDETECTED**

Not a scenario. Run because the alarm had only ever been seen firing during
teardown, when the CloudWatch agent was itself being destroyed and every metric
stopped — a trivial path, not the one it exists for.

| Field | Value |
|---|---|
| **Fault** | PodChaos `pod-failure` on `railhead-remediator`, `duration: 10m` |
| **What it tests** | Whether `railhead-dev-remediator-down` fires for a targeted remediator outage while the cluster is otherwise healthy |
| **Predicted detection** | CloudWatch ALARM ~5–6 min |
| **Predicted outcome** | **Needed a human** |
| **Measured detection** | **NONE. Alarm remained `OK` for the entire outage.** |
| **Measured outcome** | **Undetected** |
| **Evidence** | No screenshot exists — the alarm never fired. That absence is the result |
| **Cleanup verified** | CR deleted; remediator back to `1/1 Ready` |

### What actually happened

For ~10 minutes (20:53:52 → 21:03:43) the remediator was **completely
non-functional**: `0/1` Ready, **zero ready endpoints**, repeatedly
`CrashLoopBackOff`, 8 container restarts. The alarm never left `OK`.

`service_number_of_running_pods` reported **exactly `1.0` for every single
minute** of the outage.

### The open question is now resolved

**`service_number_of_running_pods` is derived from pod PHASE, not from readiness
or EndpointSlice membership.** `pod-failure` swaps the container image for a
pause image; the pod stays in `Running` phase, so the count stays at 1.

The alarm therefore only fires when the pod is **deleted** or the metric **stops
publishing entirely** — which is exactly why it fired during teardown and not
here.

**This is a genuine blind spot in the meta-monitoring.** The alarm does not
detect a remediator that is running but broken — which includes not just this
injected fault but any crashloop, deadlock, or hung process. Those are the
realistic ways a remediator fails.

### Recommended fix (NOT applied)

Alarm on a readiness-derived signal rather than a phase-derived one. Options:
- `kube_deployment_status_replicas_available{deployment="railhead-remediator"}`
  via Prometheus — but that reintroduces the in-cluster dependency the
  CloudWatch alarm exists to avoid.
- A Container Insights metric that reflects readiness, if one exists at the
  service level.
- An external synthetic probe against the remediator's `/healthz`.

The tension is real and worth stating: the alarm lives outside the cluster
*because* Prometheus cannot reliably alert on a failure inside its own cluster,
and the price of that independence is a coarser signal.
