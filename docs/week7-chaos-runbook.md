# Week 7 chaos runbook

Execution plan for the two locked scenarios. Written before the run, so the
session is execution rather than authoring. Predictions live in
`week7-chaos-scorecard.md` — fill the measured columns as you go.

Manifests are in `chaos/`. They are applied by hand and are **not** managed by
ArgoCD or Helm; nothing in `chaos/` is part of deployed state.

> **This runbook was executed on 2026-09-04. Results are in
> `week7-chaos-scorecard.md`.** The predictions below are left exactly as
> written beforehand — they are the baseline the findings are measured against,
> not a description of what happened. Three of them were wrong, which is the
> useful part. Two corrections have been folded into the commands themselves:
> the Prometheus Service name (step 2.4) and Postgres's readiness timing
> (step 3.2). Timing expectations in the prose are left uncorrected on purpose;
> the scorecard records the measured values.

**Prerequisites.** Cluster rebuilt per `rebuild-sequence.md`, all five
Applications `Synced`/`Healthy`, chaos-mesh's five pods Running, both
`railhead-api` pods Ready. Chaos Mesh's `duration` auto-recovers the fault;
the CR persists until deleted, and deleting a CR mid-run recovers the fault
immediately.

Keep a second terminal on the remediator throughout:
```
kubectl -n railhead logs -f deploy/railhead-remediator
```

---

## Step 1 — Settle the metric assumption BEFORE injecting anything

Scenario 1 rests on one unverified thing: the worker calls the API with
`timeout=5` while the API's `connect_timeout` is also `5`, so under a
partition the 500 is produced at roughly the moment the client gives up. If an
abandoned request is never counted, the alert's numerator *and* denominator
both stay flat, no series exists, and no amount of breakage fires the alert.

This isolates that question and needs no fault. The api image has python and
no curl, so the test is python; pipe it rather than passing it as an argument,
because PowerShell re-quotes multi-line arguments to native commands
(`known-gotchas.md` #20).

```
$pod = (kubectl -n railhead get pods -l app=railhead-api -o json | ConvertFrom-Json).items[0].metadata.name
Get-Content chaos\tests\metric-on-client-abandon.py | kubectl -n railhead exec -i $pod -- python -
```

**Expect** roughly 10 seconds, ending in `PASS`.

- **PASS** — abandoned requests are counted. Proceed to step 2.
- **FAIL** — stop. Scenario 1 cannot fire its alert as written. Two
  mitigations, in preference order:
  1. Rebuild the api image with `connect_timeout=2` in `app/api/main.py`, so
     the 500 lands well inside the worker's 5s budget. Correct fix, costs a CI
     cycle and an image-tag bump.
  2. Raise the client timeout in `app/worker/worker.py` above 5s. Same cost,
     less faithful to the original failure.

  Either way, **scenario 2 is unaffected** — its failures are sub-second, so
  record the FAIL as a finding and consider running scenario 2 first.

---

## Step 2 — Scenario 1: partition one api pod from Postgres

### 2.1 Render and inject

```
.\chaos\run-scenario-1.ps1
```
Prints the TARGET and SIBLING pod names and the rendered manifest, applying
nothing. Check the two names differ and note which is which. Then:
```
.\chaos\run-scenario-1.ps1 -Apply
```
**Expect** `networkchaos.chaos-mesh.org/api-postgres-partition created`,
immediately. A webhook error here would mean gotcha #29 is not settled — stop
and report rather than working around it.

### 2.2 Confirm the fault is real, within 90 seconds

Do not wait on the alert to find out whether anything happened. Read the
target pod's own counter:
```
kubectl -n railhead exec $target -- python -c "import urllib.request as u; print([l for l in u.urlopen('http://127.0.0.1:8000/metrics').read().decode().splitlines() if 'http_requests_total' in l and '/items' in l])"
```
**Expect** a `5xx` series climbing by roughly 3/min. Traffic is only ~1 request
per 20s per pod, so give it 60–90s before judging.

If nothing climbs after 2 minutes, the experiment injected nothing. Check
`kubectl -n chaos-mesh describe networkchaos api-postgres-partition` for
selection errors, and confirm the pod name in the rendered manifest matches a
live pod. **NetworkChaos has never run on this cluster** — a null result here
is a finding, not a mistake.

### 2.3 Confirm the blast radius is exactly one pod

```
kubectl -n railhead get pods -l app=railhead-api -o wide
kubectl -n railhead get endpointslices -l kubernetes.io/service-name=railhead-api -o wide
```
**Expect** both pods still `1/1 Running` and **both still in the
EndpointSlice**. `/health` is DB-free, so readiness must not flap. If the
target leaves the EndpointSlice, Kubernetes removed it before the remediator
could act and there is nothing left to quarantine — record that and stop.

### 2.4 Watch the alert fire

```
kubectl -n monitoring port-forward svc/observability-kube-prometh-prometheus 9090:9090
```
Then `http://127.0.0.1:9090/alerts` → `RailheadAPIPodErrorRate`.

**Expect** `PENDING` around 2–3 min after injection, then `FIRING` 2 minutes
later (`for: 2m`). Total roughly **4–6 minutes**. This is the longest wait in
the session and it is not a hang.

> **Screenshot:** `chaos-scenario1-alert-firing.png` — the alert FIRING with
> the `pod` label visible.

### 2.5 Watch the remediator act

In the log terminal, **expect** a quarantine line naming the target pod, and a
Slack message beginning `:hospital: Quarantined`.

> **Screenshot:** `chaos-scenario1-remediator-slack.png`

Confirm the mechanics:
```
kubectl -n railhead get pods --show-labels
kubectl -n railhead get endpointslices -l kubernetes.io/service-name=railhead-api -o wide
kubectl -n railhead get deploy railhead-api
```
**Expect** the target's `app` label rewritten to `railhead-api-quarantined`
plus `railhead.io/quarantined-at`; the target **out** of the EndpointSlice; a
brand-new api pod created by the ReplicaSet; and the Deployment back to
`2/2 READY` within ~30s.

> **Screenshot:** `chaos-scenario1-quarantined-labels.png`

### 2.6 Clean up

```
kubectl -n chaos-mesh delete networkchaos api-postgres-partition
kubectl -n railhead delete pod -l railhead.io/quarantined-at
kubectl -n railhead get pods -l app=railhead-api
```
The quarantined pod would otherwise sit until its 60-minute TTL. Deleting it
by its quarantine label is safe — that label only ever exists on quarantined
pods.

**Verify clean:** `kubectl get networkchaos -A` empty, exactly two api pods,
both Ready, both in the EndpointSlice, alert back to green.

---

## Step 3 — Scenario 2: take Postgres out from under both pods

Let the alert from scenario 1 resolve first, so the two runs do not overlap.

### 3.1 Inject

```
kubectl apply -f chaos\experiments\02-podchaos-postgres-failure.yaml
kubectl -n chaos-mesh get podchaos postgres-outage
```
**Expect** created immediately. No resolver script — `railhead-postgresql-0`
is a StatefulSet pod with a deterministic name.

### 3.2 Confirm Postgres is actually down

```
kubectl -n railhead get pods -l app.kubernetes.io/name=postgresql
kubectl -n railhead get endpointslices -l kubernetes.io/service-name=railhead-postgresql
```
**Expect** the pod still `Running` — pod-failure swaps the image for a pause
image, it does not delete the pod — but going `0/1` NotReady within ~60s and
leaving the EndpointSlice. Restart count will climb as liveness keeps failing;
that is expected, not a second fault.

### 3.3 Confirm BOTH api pods are failing

```
kubectl -n railhead logs -l app=railhead-worker --tail=20
```
**Expect** `500` on `/items` regardless of which pod serves it, appearing
within seconds. Unlike scenario 1 there is no 5s wait: the ClusterIP Service
has no backends, so connections are refused immediately.

### 3.4 The actual test — does the guard hold?

**Expect** `RailheadAPIPodErrorRate` FIRING for **both** pods ~4–6 min in, then
in the remediator log and Slack:

```
:no_entry: Refusing to quarantine `<pod>`: multiple pods are ...
```

> **Screenshot:** `chaos-scenario2-multipod-refusal-slack.png`

Confirm nothing was touched:
```
kubectl -n railhead get pods --show-labels
```
**Expect** no `railhead.io/quarantined-at` on any pod.

**If instead a pod gets quarantined, that is the important finding** — see
"If both pods get quarantined" below and act immediately.

### 3.5 Recovery and cleanup

Either wait out the 10m duration or delete early:
```
kubectl -n chaos-mesh delete podchaos postgres-outage
kubectl -n railhead get pods -l app.kubernetes.io/name=postgresql -w
```
**Expect** the real image restored and the pod back to `1/1 Ready` within
~60s, the api pods recovering on their own as the pool reconnects, and the
alert clearing within ~5 min.

**Verify clean:** `kubectl get podchaos -A` empty, Postgres `1/1`, both api
pods `1/1` and in the EndpointSlice, no quarantine labels, all alerts green.

---

## If both pods get quarantined (scenario 2 worst case)

This is a **service outage** and the recovery is quick. It happens if
Alertmanager delivers the two pods as separate payloads instead of one group,
so each is evaluated with `multi_pod=False`, and the `ready_replicas` backstop
races because Deployment status lags.

```
kubectl -n railhead delete pod -l railhead.io/quarantined-at
kubectl -n railhead get deploy railhead-api -w
```
The ReplicaSet rebuilds to 2 replicas within ~30s. Then remove the chaos
(3.5). **Record it as the headline finding** — it would mean the safety
argument in `CLAUDE.md` about `group_by` is wrong, which is a real latent bug
worth a gotcha and a fix.

---

## Optional — the meta-monitoring check (~10 min, not a scenario)

Only if time allows. Holds the remediator down long enough for the CloudWatch
alarm to notice. Resolve the pod name first, then apply a PodChaos identical
in shape to scenario 2's but targeting `railhead-remediator`, with
`duration: 10m`.

```
kubectl -n railhead get pods -l app=railhead-remediator
```

Copy `chaos/experiments/02-podchaos-postgres-failure.yaml` to a scratch file,
change `metadata.name` to `remediator-outage` and the selector's pod name to
the remediator pod, then apply it. Watch:

```
aws cloudwatch describe-alarms --region us-east-1 --alarm-names railhead-dev-remediator-down --query "MetricAlarms[].[StateValue,StateReason]" --output table
```
**Expect** ALARM after ~5–6 min (readiness ~30s, then `datapoints_to_alarm=3`
at `period=60`, plus Container Insights' 1/min publish and CloudWatch
evaluation lag).

**It may never fire, and that is a real result.**
`service_number_of_running_pods` comes from the API server with a `Service`
dimension. If that count derives from EndpointSlice membership, a NotReady pod
drops out and the alarm fires. If it derives from pod phase, the pod is still
`Running` and the alarm stays OK — meaning the meta-monitoring does not detect
the case it exists for. Record whichever happens; "Undetected" is a valid
outcome.

Clean up with `kubectl -n chaos-mesh delete podchaos remediator-outage`.

---

## Before ending the session

- All chaos CRs deleted: `kubectl get podchaos,networkchaos -A` returns
  nothing. This is a **prerequisite** for teardown, not a nicety — once the
  chaos-mesh namespace goes, a surviving chaos CR cannot be deleted at all
  (`teardown-sequence.md` step 4).
- No quarantine labels left on any pod.
- Scorecard's measured columns filled in.
- Screenshots committed separately from code (`CLAUDE.md`).
- Then `teardown-sequence.md`, in full.
