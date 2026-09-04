# Week 7 chaos runbook

Execution steps for the two chaos scenarios and the meta-monitoring check.
**Executed once, 2026-09-04** — timings below are measured, not predicted.
Results and analysis: [`week7-chaos-scorecard.md`](week7-chaos-scorecard.md).

Manifests are in [`../chaos/`](../chaos/). They are applied by hand and are
**not** managed by ArgoCD or Helm; nothing in `chaos/` is deployed state.

**Prerequisites.** Cluster rebuilt per `rebuild-sequence.md`, five Applications
`Synced`/`Healthy`, chaos-mesh's five pods Running, both `railhead-api` pods
Ready.

**Chaos Mesh `duration`** auto-recovers the fault; the CR persists until
deleted. Deleting a CR mid-run recovers immediately.

Keep a second terminal open throughout:
```
kubectl -n railhead logs -f deploy/railhead-remediator
```

---

## Step 1 — Assumption test (before any injection)

Scenario 1 depends on `http_requests_total` incrementing when the client
abandons a request — the worker's `timeout=5` ties the API's `connect_timeout=5`.
If abandoned requests aren't counted, the alert's numerator *and* denominator
stay flat and nothing can fire.

The api image has python and no curl. Pipe the script rather than passing it as
an argument — PowerShell re-quotes multi-line arguments (gotcha #20).

```
$pod = (kubectl -n railhead get pods -l app=railhead-api -o json | ConvertFrom-Json).items[0].metadata.name
Get-Content chaos\tests\metric-on-client-abandon.py | kubectl -n railhead exec -i $pod -- python -
```

**Measured: PASS**, ~10s, delta exactly 5.0 for 5 abandoned requests.

If it ever FAILs, stop: rebuild the api image with `connect_timeout=2` so the
500 lands inside the worker's budget. Scenario 2 is unaffected either way — its
failures are sub-second.

---

## Step 2 — Scenario 1: partition one api pod from Postgres

### 2.1 Render, then inject

```
.\chaos\run-scenario-1.ps1
.\chaos\run-scenario-1.ps1 -Apply
```
The first prints TARGET and SIBLING pod names and the rendered manifest without
applying. Confirm the names differ.

**Expect** `networkchaos.chaos-mesh.org/api-postgres-partition created`. A
webhook error here means gotcha #29 is unsettled — stop and report.

### 2.2 Confirm the fault is real, within 90s

Do not wait on the alert to learn whether anything happened.

```
kubectl -n railhead exec $target -- python -c "import urllib.request as u; print([l for l in u.urlopen('http://127.0.0.1:8000/metrics').read().decode().splitlines() if 'http_requests_total' in l and '/items' in l])"
```

**Expect** a `5xx` series climbing ~3/min. Traffic is only ~1 request per 20s
per pod, so allow 60–90s.

> **Do not poll `/metrics` repeatedly.** Every read adds a 2xx to the alert's
> denominator and pushes the ratio *down* — with a 2% margin (gotcha #33) you
> can suppress the alert by observing it. Use Prometheus instead:
> ```
> kubectl -n monitoring port-forward svc/observability-kube-prometh-prometheus 9090:9090
> ```
> Note the Service name is `observability-kube-prometh-prometheus` — Helm
> truncates it.

If nothing climbs after 2 minutes, check
`kubectl -n chaos-mesh describe networkchaos api-postgres-partition` for
selection errors and confirm the rendered pod name matches a live pod.

### 2.3 Confirm blast radius is one pod

```
kubectl -n railhead get pods -l app=railhead-api -o wide
kubectl -n railhead get endpointslices -l kubernetes.io/service-name=railhead-api -o wide
```
**Measured:** both pods stayed `1/1 Running` and both stayed in the
EndpointSlice. `/health` is DB-free so readiness must not flap.

### 2.4 Watch the alert

`http://127.0.0.1:9090/alerts` → `RailheadAPIPodErrorRate`.

**Measured: FIRING at 13m52s.** PENDING at 5m39s, **abandoned** at 7m12s when
the ratio dipped below 0.5, PENDING again at 11m49s, FIRING at 13m52s. Expect
oscillation around the threshold and at least one abandoned PENDING — this is
normal here, not a hang.

> Screenshot: `chaos-scenario1-alert-firing.png` — **not captured**; the alert
> resolved before capture. The Slack message proves it fired.

### 2.5 Watch the remediator act

**Measured: quarantine 12s after FIRING.** Slack message begins
`:hospital: Quarantined`.

```
kubectl -n railhead get pods --show-labels
kubectl -n railhead get endpointslices -l kubernetes.io/service-name=railhead-api -o wide
kubectl -n railhead get deploy railhead-api
```
**Measured:** target's `app` label rewritten to `railhead-api-quarantined` plus
`railhead.io/quarantined-at`; target out of the EndpointSlice; replacement pod
created; Deployment back to `2/2` in ~30s.

> Screenshots: `chaos-scenario1-remediator-slack.png`,
> `chaos-scenario1-failure-mechanism.png`,
> `chaos-scenario1-quarantined-labels.png`

### 2.6 Clean up

```
kubectl -n chaos-mesh delete networkchaos api-postgres-partition
kubectl -n railhead delete pod -l railhead.io/quarantined-at
kubectl -n railhead get pods -l app=railhead-api
```
The CR auto-recovers at `duration` but still needs deleting. The quarantined pod
otherwise sits until its 60-minute TTL — and that sweep only runs when a webhook
fires, not on a timer.

**Verify:** `kubectl get networkchaos -A` empty, two api pods, both Ready and in
the EndpointSlice.

---

## Step 3 — Scenario 2: Postgres outage under both pods

Let scenario 1's alert resolve first so the runs don't overlap.

### 3.1 Inject

```
kubectl apply -f chaos\experiments\02-podchaos-postgres-failure.yaml
kubectl -n chaos-mesh get podchaos postgres-outage
```
No resolver script — `railhead-postgresql-0` is a StatefulSet pod with a
deterministic name.

### 3.2 Confirm Postgres is down

```
kubectl -n railhead get pods -l app.kubernetes.io/name=postgresql
kubectl -n railhead get endpointslices -l kubernetes.io/service-name=railhead-postgresql
```
**Measured: ~60s to go `0/1` NotReady** (Bitnami's readiness uses
`failureThreshold: 6`). The pod stays in `Running` phase — `pod-failure` swaps
the image for a pause image, it does not delete the pod. Verify the swap
directly if in doubt:
```
kubectl -n railhead get pod railhead-postgresql-0 -o jsonpath="{.spec.containers[0].image}"
```
**Measured:** `gcr.io/google-containers/pause:latest`. Restart count climbs as
liveness keeps failing — expected, not a second fault.

### 3.3 Confirm both api pods are failing

```
kubectl -n railhead logs -l app=railhead-worker --tail=20
```
**Measured: failures within 30s of injection.** No 5s wait — the ClusterIP
Service has no ready backends, so connections are refused immediately
(`Connection refused`, not `timeout expired`).

### 3.4 The test — does the guard hold?

**Measured: it did not.** Both pods were quarantined **300s apart** (exactly
Alertmanager's `group_interval`), with **zero refusals**. Two webhooks arrived,
each carrying one firing pod.

```
kubectl -n railhead get pods --show-labels
grep -cE "POST /webhook" <remediator log>
grep -E "Quarantined|Refusing" <remediator log>
```

> Screenshots: `chaos-scenario2-grouped-alert.png`,
> `chaos-scenario2-cascade-state.png`
> `chaos-scenario2-multipod-refusal-slack.png` — **does not exist; there was no
> refusal.** That absence is the finding.

Mechanism and severity analysis: scorecard §2 and gotcha #32.

### 3.5 Recovery and cleanup

```
kubectl -n chaos-mesh delete podchaos postgres-outage
kubectl -n railhead delete pod -l railhead.io/quarantined-at
kubectl -n railhead get pods -l app.kubernetes.io/name=postgresql -w
```
**Measured:** Postgres back to `1/1` in ~60s; api pods recovered unaided;
Deployment returned to `2/2`.

**Verify:** `kubectl get podchaos -A` empty, Postgres `1/1`, two api pods Ready,
no quarantine labels.

---

## If both pods get quarantined

This happened. It is recoverable in ~30 seconds:

```
kubectl -n railhead delete pod -l railhead.io/quarantined-at
kubectl -n railhead get deploy railhead-api -w
```
The ReplicaSet rebuilds to 2 replicas. Then remove the chaos CR.

**It was not a total outage** — `readyReplicas` never hit 0 and
`MIN_REMAINING_READY` held at every decision. Expect degradation, not downtime.

---

## Step 4 — Meta-monitoring check (~12 min)

Copy `chaos/experiments/02-podchaos-postgres-failure.yaml` to a scratch file,
rename it `remediator-outage`, point the selector at the live remediator pod,
keep `duration: 10m`, and apply it.

```
kubectl -n railhead get pods -l app=railhead-remediator
aws cloudwatch describe-alarms --region us-east-1 --alarm-names railhead-dev-remediator-down --query "MetricAlarms[].[StateValue,StateReason]" --output table
```

**Measured: the alarm never fired.** The remediator sat `0/1` Ready with zero
endpoints, `CrashLoopBackOff`, 8 restarts, for the full 10 minutes, while
`service_number_of_running_pods` reported `1.0` every minute. The metric counts
pod **phase**, not readiness (gotcha #34).

> Screenshot: `chaos-check-remediator-down-alarm.png` — **does not exist; the
> alarm never fired.** That absence is the finding.

Clean up: `kubectl -n chaos-mesh delete podchaos remediator-outage`, then
confirm the remediator returns to `1/1 Ready`.

---

## Before ending the session

- **All chaos CRs deleted:** `kubectl get podchaos,networkchaos -A` returns
  nothing. This is a **prerequisite for teardown**, not tidiness — once the
  chaos-mesh namespace is gone, its webhooks survive with `failurePolicy: Fail`
  and a leftover chaos CR becomes undeletable (`teardown-sequence.md` step 4).
- **No quarantine labels:** `kubectl -n railhead get pods -l railhead.io/quarantined-at`
  returns nothing.
- Scorecard's measured columns filled in.
- Screenshots committed separately from code (`CLAUDE.md`).
