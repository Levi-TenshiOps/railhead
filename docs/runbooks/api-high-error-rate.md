# Runbook: Railhead API high error rate (availability SLO burn-rate)

Alerts covered: `RailheadAPIAvailabilityBurnRateCritical`, `RailheadAPIAvailabilityBurnRateWarning`

## What this alert means

The `railhead-api` availability SLO is 99% of requests non-5xx over a rolling 30-day window (1% error budget). This isn't "the API is down" — it's "the API is failing fast enough that, if this rate continues, the entire monthly error budget will be gone well before the 30 days are up."

- **Critical** fires when the 5xx rate has held above 14.4x the sustainable rate for both the last 1h and the last 5m. At that rate, the 30-day budget is gone in about 2 days.
- **Warning** fires at 6x the sustainable rate, over 6h and 30m windows. At that rate, the budget is gone in about 5 days.

Both windows (long + short) have to agree before the alert fires — this is deliberate. It means the alert clears on its own within minutes of the underlying problem actually stopping, rather than staying lit for up to an hour just because the long window still remembers the bad data. If you see this alert, the error rate is (or very recently was) genuinely elevated right now, not a stale echo of something already fixed.

Only 5xx counts as "bad" here — 4xx (bad client requests) is deliberately excluded, since it doesn't represent the service failing to do its job.

## First things to check

1. **Grafana → `Railhead — API Metrics` dashboard.** The "Error Rate (4xx/5xx)" panel will show you whether this is a sudden spike or a slow climb, and the "Request Rate by Endpoint" panel tells you if it's isolated to one handler or spread across all of them.
2. **Grafana → `Railhead — Cluster Health` dashboard.** Check "Pod Restarts" and "Pod Count by Namespace" first — a crash-looping pod is the single most common cause here (see below), and this dashboard shows it at a glance before you even need to touch `kubectl`.
3. **Loki, via Grafana Explore → Loki datasource.** Start with:
   ```
   {namespace="railhead", container="api"} |= "ERROR"
   ```
   This surfaces the actual exception tracebacks, which almost always name the real cause directly (e.g. a `psycopg2.OperationalError` names the exact Postgres failure mode).
4. **`kubectl get pods -n railhead`** — fast sanity check for `CrashLoopBackOff`, `ImagePullBackOff`, or a pod stuck at `0/1` ready.

## Common causes

- **Postgres unreachable.** The single most likely cause given this app's shape — every `/items` call needs a DB connection, `/health` doesn't. If only `/items` is failing while `/health` stays clean, this is almost certainly it. Check `kubectl get pods -n railhead -l app.kubernetes.io/name=postgresql` and `kubectl logs` on the api pods for `psycopg2.OperationalError`. (This is exactly the failure mode used to test this alert end-to-end during Week 6 Session A — see the `[[railhead-project]]` session notes for the deliberate DB-outage-and-burst-traffic test that first triggered it for real.)
- **A bad deploy crash-looping.** Check `kubectl get pods -n railhead` for `CrashLoopBackOff`, then `kubectl logs <pod> --previous` for the actual startup exception. A `TypeError` or import error at module load time will crash every pod immediately and consistently — the API's own metrics endpoint won't even come up, so Prometheus will also show `TargetDown` for `railhead-api` alongside this alert.
- **Resource exhaustion.** Both api and worker have tight CPU/memory limits (see `kubernetes/helm-charts/railhead-app/values.yaml`). An OOMKilled pod restarts and briefly serves nothing while it comes back up. Check `kubectl describe pod` for `OOMKilled` in recent terminated-container state.
- **Postgres itself unhealthy**, not just unreachable — e.g. its own PVC full, or a bad password after a config change (see the Postgres-auth-instability gotcha in project history: ArgoCD re-rendering the Bitnami chart can rotate its auto-generated password out from under an already-initialized pod; this repo now pins that password to a Terraform-managed secret specifically to prevent it, but it's worth ruling out if the underlying infra was touched recently).

## Self-resolve vs. escalate

**Self-resolve if:**
- A single pod is crash-looping and the fix is an obvious redeploy (bad image tag, config typo) — delete the pod / bump the tag / re-sync the ArgoCD Application, verify the error rate drops in Grafana, done.
- Postgres was briefly unreachable (network blip, node replacement) and has already recovered — confirm `/items` returns `200` again and the error rate is trending back down; no further action needed once the burn-rate alert itself clears.

**Escalate to a human (today — there is no automated remediation yet) if:**
- The cause isn't obvious within a few minutes of checking the dashboard + Loki + pod status above.
- Postgres data itself looks wrong or missing (not just unreachable) — don't guess at a fix that touches data.
- The critical alert has been firing for more than ~15 minutes with no clear cause identified — at the 14.4x burn rate, that's already a meaningful chunk of the monthly error budget gone.
- Fixing it would require touching Terraform/infra (not just `kubectl`) — e.g. the EKS node group, IAM, or anything outside the `railhead` namespace.

Automated first-response (attempt a fix — restart/scale/cordon — before escalating) is planned for Week 6 Session B, not built yet as of this runbook's writing. Until then, every fast-burn alert needs a human to look at it.
