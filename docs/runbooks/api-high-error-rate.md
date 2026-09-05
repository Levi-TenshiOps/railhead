# Runbook: Railhead API high error rate (availability SLO burn-rate)

Alerts covered: `RailheadAPIAvailabilityBurnRateCritical`, `RailheadAPIAvailabilityBurnRateWarning`

## What this alert means

The `railhead-api` availability SLO is 99% of requests non-5xx over a rolling 30-day window (1% error budget). This isn't "the API is down" — it's "the API is failing fast enough that, if this rate continues, the entire monthly error budget will be gone well before the 30 days are up."

- **Critical** fires when the 5xx rate has held above 14.4x the sustainable rate for both the last 1h and the last 5m. At that rate, the 30-day budget is gone in about 2 days.
- **Warning** fires at 6x the sustainable rate, over 6h and 30m windows. At that rate, the budget is gone in about 5 days.

Both windows (long + short) have to agree before the alert fires — this is deliberate. It means the alert clears on its own within minutes of the underlying problem actually stopping, rather than staying lit for up to an hour just because the long window still remembers the bad data. If you see this alert, the error rate is (or very recently was) genuinely elevated right now, not a stale echo of something already fixed.

Only 5xx counts as "bad" here — 4xx (bad client requests) is deliberately excluded, since it doesn't represent the service failing to do its job. `/health` is excluded too: readiness probes it every 5s and liveness every 10s, so probe traffic outnumbers real requests roughly 6:1 and never fails. Counting it would dilute the error ratio about 7x and hide real outages.

## First things to check

1. **Grafana → `Railhead — API Metrics` dashboard.**
   - **Error Rate (4xx/5xx)** — spike vs. slow climb. Aggregate only; for the per-endpoint breakdown run in Explore:
     ```
     sum by (handler) (rate(http_requests_total{job="railhead-api", status=~"5xx"}[5m]))
     ```
   - **Request Rate by Endpoint** — won't move during a failure; a 500 is still a request. Read traffic shape instead:
     - steady ~0.1 req/s → traffic arriving, failure is in responses. Expected here.
     - zero → worker or Service is broken; the SLO is measuring nothing and will report healthy. Its own incident.
     - spiking → load-related; check saturation first.
     - `/health` (~0.6 req/s) flattens the other series — hide it via the legend.
   - **p95 Latency by Endpoint** — "slow" vs. "erroring."
     - errors up, latency flat/down → fast failure (DNS, connection refused, pool exhausted); nothing waiting on a timeout.
     - latency up first, then errors → saturation or timeouts.
     - latency up, errors flat → degraded but working; latency budget only.
     - buckets are 0.1/0.3/0.5/1, so p95 is interpolated: "0.29" means "upper part of 0.1–0.3," not 290ms. Only movement across a boundary is real.
2. **Grafana → `Railhead — Cluster Health` dashboard.** Check "Pod Restarts" and "Pod Count by Namespace" first — a crash-looping pod is the single most common cause here (see below), and this dashboard shows it at a glance before you even need to touch `kubectl`.
3. **Loki, via Grafana Explore → Loki datasource.** Start with:
   ```
   {namespace="railhead", container="api"} |~ "Error:|Exception:"
   ```
   Returns just the exception line that names the cause, e.g. `psycopg2.OperationalError: connection to server at "..." port 5432 failed: Connection refused`. One line per failed request — enough to identify the failure mode before reading anything else.

   Then read the surrounding traceback:
   ```
   {namespace="railhead", container="api"} != "/health" != "/metrics"
   ```
   Drops the access-log chatter from probes and scrapes (~20/min per pod), leaving the `/items` requests and their full tracebacks. Exclude rather than match: Loki filters line by line, so any keyword filter returns disconnected fragments instead of a readable stack. Add `pod="<name>"` to isolate one replica.
4. **`kubectl get pods -n railhead`** — fast sanity check for `CrashLoopBackOff`, `ImagePullBackOff`, or a pod stuck at `0/1` ready.

## Common causes

- **Postgres unreachable.** The single most likely cause given this app's shape — every `/items` call needs a DB connection, `/health` doesn't. If only `/items` is failing while `/health` stays clean, this is almost certainly it. Check `kubectl get pods -n railhead -l app.kubernetes.io/name=postgresql` and `kubectl logs` on the api pods for `psycopg2.OperationalError`. (This is exactly the failure mode used to test this alert end-to-end: Postgres was deliberately taken offline and hit with a burst of traffic to trigger it for real. The closely-related per-pod fault injection is recorded step-by-step in [`docs/remediator-trigger-validation.md`](../remediator-trigger-validation.md).)
- **A bad deploy crash-looping.** Check `kubectl get pods -n railhead` for `CrashLoopBackOff`, then `kubectl logs <pod> --previous` for the actual startup exception. A `TypeError` or import error at module load time will crash every pod immediately and consistently — the API's own metrics endpoint won't even come up, so Prometheus will also show `TargetDown` for `railhead-api` alongside this alert.
- **Resource exhaustion.** Both api and worker have tight CPU/memory limits (see `kubernetes/helm-charts/railhead-app/values.yaml`). An OOMKilled pod restarts and briefly serves nothing while it comes back up. Check `kubectl describe pod` for `OOMKilled` in recent terminated-container state.
- **Postgres itself unhealthy**, not just unreachable — e.g. its own PVC full, or a bad password after a config change (see the Postgres-auth-instability gotcha in project history: ArgoCD re-rendering the Bitnami chart can rotate its auto-generated password out from under an already-initialized pod; this repo now pins that password to a Terraform-managed secret specifically to prevent it, but it's worth ruling out if the underlying infra was touched recently).

## Self-resolve vs. escalate

**Self-resolve if:**
- A single pod is crash-looping and the fix is an obvious redeploy (bad image tag, config typo) — delete the pod / bump the tag / re-sync the ArgoCD Application, verify the error rate drops in Grafana, done.
- Postgres was briefly unreachable (network blip, node replacement) and has already recovered — confirm `/items` returns `200` again and the error rate is trending back down; no further action needed once the burn-rate alert itself clears.

**Escalate to a human if:** (these aggregate burn-rate alerts have no automated response — see the pod-quarantine section below for the one alert that does)
- The cause isn't obvious within a few minutes of checking the dashboard + Loki + pod status above.
- Postgres data itself looks wrong or missing (not just unreachable) — don't guess at a fix that touches data.
- The critical alert has been firing for more than ~15 minutes with no clear cause identified — at the 14.4x burn rate you're spending budget about 14x faster than the SLO allows, and every further hour costs ~2% of the month's allowance.
- Fixing it would require touching Terraform/infra (not just `kubectl`) — e.g. the EKS node group, IAM, or anything outside the `railhead` namespace.

## Automated response: `RailheadAPIPodErrorRate` (pod quarantine)

A different, narrower alert than the two above: it fires when a pod serves majority 5xx on non-health-check requests. The expression is per-pod and does **not** compare replicas — one pod firing alone is the corrupted-connection-pool case; several firing at once is a shared outage. The remediator makes that distinction itself, because Alertmanager hands it every firing alert in one payload. Unlike the burn-rate alerts, this one has an automated first response: `railhead-remediator` quarantines the named pod, no human needed for the common case.

**What you'll see:** a `:hospital:` Slack message naming the pod, with an evidence block (recent logs, restart count, image) captured *before* the action, so the failure evidence survives the pod. "Quarantined" means its `app` label was patched to `railhead-api-quarantined`, dropping it out of the Service selector (traffic stops) and the ReplicaSet selector (a replacement is created) — full mechanism in the root README's [Automated Remediation](../../README.md#automated-remediation) section.

**What this actually fixes:** the ReplicaSet sees one fewer pod matching its selector and creates a replacement, which builds a fresh connection pool at startup — so the corrupted-pool failure doesn't carry over and the `/items` 5xx rate returns to zero. Readiness allows ~5-10s after the container starts, so expect recovery well under a minute unless the image has to be pulled. Until then you're at reduced capacity; the `MIN_REMAINING_READY` guard is what keeps at least one pod serving. Confirm with `kubectl get pods -n railhead` (new pod, `1/1`) and the Error Rate panel. If errors persist once the replacement is Ready, the fault wasn't pod-local — escalate.

**Reading the follow-up `resolved` alert:** once the pod is quarantined, it stops receiving traffic and Prometheus stops scraping it, so the per-pod error-rate series it was firing on simply disappears — Alertmanager reports this as the alert resolving. **A `resolved` notification here means the quarantine worked, not that the underlying problem fixed itself.** Don't read it as "safe to ignore" the way you would for a burn-rate alert that cleared because traffic actually recovered.

**What happens to the quarantined pod:** it keeps running, untouched, for inspection — `kubectl logs`/`kubectl exec` still work against it by name. It's fully orphaned (the ReplicaSet releases its `ownerReference`), so nothing will ever garbage-collect it on its own. The remediator deletes it itself after a 60-minute TTL. If you need to inspect it, do so within that window.

**When this still escalates to a human:** more than one pod alerting in the same Alertmanager payload (shared failure — quarantining can't help, every replacement would be equally broken), 3+ quarantines within 15 minutes (a bad deployment, not one bad pod), or quarantining would leave zero pods serving traffic. In all three cases the remediator posts a `:no_entry:` refusal to Slack and takes no action — treat that exactly like any other page.
