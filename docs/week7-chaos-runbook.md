# Week 7 chaos runbook

Execution steps for the two chaos scenarios and the meta-monitoring check.
**Executed 2026-09-04** — timings below are measured. Results and mechanisms:
[`week7-chaos-scorecard.md`](week7-chaos-scorecard.md).

Manifests are in [`../chaos/`](../chaos/) — hand-applied, not deployed state.
`duration` auto-recovers the fault; the CR persists until deleted, and deleting
mid-run recovers immediately.

**Prerequisites:** cluster rebuilt per `rebuild-sequence.md`, five Applications
`Synced`/`Healthy`, chaos-mesh's five pods Running, both `railhead-api` pods
Ready. Keep a second terminal on `kubectl -n railhead logs -f deploy/railhead-remediator`.

---

## 1 — Assumption test (before any injection)

Scenario 1 needs `http_requests_total` to increment when a client abandons a
request — the worker's `timeout=5` ties the API's `connect_timeout=5`. Pipe the
script; PowerShell re-quotes multi-line arguments (gotcha #20). The api image has
python, no curl.

```powershell
$pod = (kubectl -n railhead get pods -l app=railhead-api -o json | ConvertFrom-Json).items[0].metadata.name
Get-Content chaos\tests\metric-on-client-abandon.py | kubectl -n railhead exec -i $pod -- python -
```

**Measured: PASS**, ~10s, delta exactly 5.0 for 5 abandoned requests.

On FAIL, rebuild the api image with `connect_timeout=2`. Scenario 2 is
unaffected either way — its failures are sub-second.

---

## 2 — Scenario 1: partition one api pod from Postgres

### 2.1 Render, then inject
```powershell
.\chaos\run-scenario-1.ps1
.\chaos\run-scenario-1.ps1 -Apply
```
The first prints TARGET and SIBLING and the rendered manifest without applying.
Confirm the names differ. **Expect** `networkchaos.chaos-mesh.org/api-postgres-partition created`.
A webhook error means gotcha #29 is unsettled — stop and report.

### 2.2 Confirm the fault is real, within 90s
```powershell
kubectl -n monitoring port-forward svc/observability-kube-prometh-prometheus 9090:9090
```
Service name is `observability-kube-prometh-prometheus` — Helm truncates it.

> **Do not poll the pod's `/metrics` to check progress.** Query Prometheus
> instead. This was load-bearing on the first run, when `/metrics` sat in the
> alert denominator with a 2% margin (gotcha #33) and every read pushed the ratio
> further down — you could suppress the alert by observing it. The rules now
> exclude `/metrics`, so the hazard is gone, but the habit is still right: the
> pod's own counters are not the signal the alert reads.

If nothing changes after 2 minutes, check
`kubectl -n chaos-mesh describe networkchaos api-postgres-partition` for
selection errors and confirm the rendered pod name matches a live pod.

### 2.3 Confirm blast radius
```powershell
kubectl -n railhead get pods -l app=railhead-api -o wide
kubectl -n railhead get endpointslices -l kubernetes.io/service-name=railhead-api -o wide
```
**Measured:** both pods stayed `1/1 Running` and in the EndpointSlice. `/health`
is DB-free, so readiness must not flap.

### 2.4 Watch the alert
`http://127.0.0.1:9090/alerts` → `RailheadAPIPodErrorRate`.

**First run (2026-09-04), `/metrics` still in the denominator: FIRING at 13m52s.**
PENDING 5m39s → **abandoned** 7m12s → PENDING 11m49s → FIRING 13m52s, oscillating
0.438–0.550 around the threshold.

**Re-run (2026-09-05) after excluding `/metrics`: FIRING at 5m46s.** PENDING
3m46s, no abandoned period, ratio climbing monotonically to 1.0. This is what to
expect now — a PENDING that holds and converts. **An abandoned PENDING today
means something is wrong**, not that the alert is being slow.

> No screenshot of the alert in FIRING state exists — it had already resolved by
> the time one was taken. The Slack message is the record that it fired.

### 2.5 Watch the remediator act
**Measured: quarantine 12s after FIRING**, Slack message begins `:hospital: Quarantined`.
```powershell
kubectl -n railhead get pods --show-labels
kubectl -n railhead get endpointslices -l kubernetes.io/service-name=railhead-api -o wide
kubectl -n railhead get deploy railhead-api
```
**Measured:** `app` label rewritten to `railhead-api-quarantined` plus
`railhead.io/quarantined-at`; target out of the EndpointSlice; replacement
created; Deployment back to `2/2` in ~30s.

> `chaos-scenario1-remediator-slack.png` · `chaos-scenario1-failure-mechanism.png`
> · `chaos-scenario1-quarantined-labels.png`

### 2.6 Clean up
```powershell
kubectl -n chaos-mesh delete networkchaos api-postgres-partition
kubectl -n railhead delete pod -l railhead.io/quarantined-at
kubectl -n railhead get pods -l app=railhead-api
```
The CR auto-recovers at `duration` but still needs deleting. The quarantined pod
otherwise sits until its 60-minute TTL — and that sweep runs only when a webhook
fires, not on a timer.

**Verify:** `kubectl get networkchaos -A` empty, two api pods Ready and in the
EndpointSlice.

---

## 3 — Scenario 2: Postgres outage under both pods

Let scenario 1's alert resolve first.

### 3.1 Inject
```powershell
kubectl apply -f chaos\experiments\02-podchaos-postgres-failure.yaml
kubectl -n chaos-mesh get podchaos postgres-outage
```
No resolver script — `railhead-postgresql-0` is a StatefulSet pod.

### 3.2 Confirm Postgres is down
```powershell
kubectl -n railhead get pods -l app.kubernetes.io/name=postgresql
kubectl -n railhead get pod railhead-postgresql-0 -o jsonpath="{.spec.containers[0].image}"
```
**Measured: ~60s to `0/1` NotReady** (Bitnami readiness `failureThreshold: 6`),
image swapped to `gcr.io/google-containers/pause:latest`. The pod stays in
`Running` phase — `pod-failure` does not delete it. Restart count climbs as
liveness keeps failing; expected.

### 3.3 Confirm both api pods are failing
```powershell
kubectl -n railhead logs -l app=railhead-worker --tail=20
```
**Measured: failures within 30s.** No 5s wait — the ClusterIP Service has no
ready backends, so connections are refused immediately (`Connection refused`,
not `timeout expired`).

### 3.4 The test — does the guard hold?
```powershell
kubectl -n railhead get pods --show-labels
kubectl -n railhead logs deploy/railhead-remediator --tail=2000 | Select-String "POST /webhook" | Measure-Object -Line
kubectl -n railhead logs deploy/railhead-remediator --tail=2000 | Select-String -Pattern "Quarantined|Refusing"
```
**Measured: it did not.** Both pods quarantined **300s apart**, zero refusals,
two webhooks each carrying one firing pod. Mechanism: the scorecard's scenario 2
section, and gotcha #32.

> `chaos-scenario2-grouped-alert.png` · `chaos-scenario2-cascade-state.png`
>
> **There is no refusal screenshot, because no refusal happened.** That absence
> is the result of this scenario, not a gap in the evidence.

### 3.5 Recovery and cleanup
```powershell
kubectl -n chaos-mesh delete podchaos postgres-outage
kubectl -n railhead delete pod -l railhead.io/quarantined-at
kubectl -n railhead get pods -l app.kubernetes.io/name=postgresql -w
```
**Measured:** Postgres back to `1/1` in ~60s, api pods recovered unaided,
Deployment returned to `2/2`.

**Verify:** `kubectl get podchaos -A` empty, Postgres `1/1`, two api pods Ready,
no quarantine labels.

### If both pods get quarantined
Happened, and recoverable in ~30s:
```powershell
kubectl -n railhead delete pod -l railhead.io/quarantined-at
kubectl -n railhead get deploy railhead-api -w
```
Then remove the chaos CR. `readyReplicas` never hit 0 — expect degradation, not
downtime.

---

## 4 — Meta-monitoring check (~12 min)

Copy `chaos/experiments/02-podchaos-postgres-failure.yaml` to a scratch file,
rename it `remediator-outage`, point the selector at the live remediator pod,
keep `duration: 10m`, apply.

```powershell
kubectl -n railhead get pods -l app=railhead-remediator
aws cloudwatch describe-alarms --region us-east-1 --alarm-names railhead-dev-remediator-down --query "MetricAlarms[].[StateValue,StateReason]" --output table
```

**Measured: the alarm never fired.** The remediator sat `0/1` Ready with zero
endpoints, `CrashLoopBackOff`, 8 restarts, for the full 10 minutes, while
`service_number_of_running_pods` reported `1.0` every minute (gotcha #34).

> **There is no alarm screenshot, because the alarm never fired.** That is the
> finding this check produced.

Clean up: `kubectl -n chaos-mesh delete podchaos remediator-outage`, confirm the
remediator returns to `1/1 Ready`.

---

## Before ending the session

- **All chaos CRs deleted** — `kubectl get podchaos,networkchaos -A` returns
  nothing. This is a **prerequisite for teardown**: once the chaos-mesh namespace
  is gone its webhooks survive with `failurePolicy: Fail`, and a leftover chaos
  CR becomes undeletable (`teardown-sequence.md` step 4).
- **No quarantine labels** — `kubectl -n railhead get pods -l railhead.io/quarantined-at`
  returns nothing.
- Scorecard filled in; screenshots committed separately from code (`CLAUDE.md`).
