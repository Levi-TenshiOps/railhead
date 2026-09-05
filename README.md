# Railhead — Production-Grade SRE Platform on AWS

Railhead is a portfolio project built to prove something specific: that I can run the full lifecycle of a production service on AWS, not just describe it in an interview. It provisions its own infrastructure with Terraform, deploys itself through GitOps with ArgoCD, and now monitors itself with real SLOs and burn-rate alerting — verified end-to-end against a live AWS account, not just configured and left untested.

Automated remediation is built: when a pod is serving majority errors while its siblings stay healthy, a script quarantines it — relabeling it out of the Service and ReplicaSet selectors so traffic stops and a healthy replacement is created, while the broken pod keeps running for inspection.

Chaos engineering, with predictions written down first, then turned up a real defect in that remediator — see [Chaos Engineering](#chaos-engineering) below.

## Why "Railhead"

A railhead is where a rail line physically ends and cargo transfers onward to its next mode of transport — that's the metaphor: code "arrives" from git here and gets carried into running infrastructure. It's also a nod to VxRail, the hyperconverged platform I've supported in production for years. The name sits at the intersection of both.

## Architecture

Everything below is live and verified against a real AWS account — nothing here is aspirational.

![Railhead architecture: developer push through GitHub Actions and Trivy into ECR, ArgoCD syncing the api pods, Prometheus and Alertmanager driving the remediator, Chaos Mesh injecting faults inside the cluster and CloudWatch observing from outside it](screenshots/railhead-architecture-simple.png)

Read it as three loops. **Delivery** runs left to right: a push builds and scans an image into ECR, while ArgoCD separately watches `main` and deploys — two paths that never cross. **Detection and repair** is the cycle in the middle: Prometheus scrapes the api pods, hands firing alerts to Alertmanager, and Alertmanager both notifies Slack and calls the remediator, which relabels the bad pod out of the Service so a replacement is created. **Verification** is the two components at the edges: Chaos Mesh sits *inside* the cluster injecting faults (deployed by Terraform rather than ArgoCD, for reasons in [Known Gotchas](docs/known-gotchas.md) #29), and CloudWatch sits *outside* the cluster boundary — which is precisely why it can still report on a failure that takes the in-cluster monitoring down with it.

Two paths lead into the cluster and they never cross: container images travel through GitHub Actions into ECR, while *configuration* travels through ArgoCD. CI holds no cluster credentials and never runs `kubectl`; ArgoCD holds no AWS credentials. Neither one can do the other's job, which is the point.

- **Terraform state backend** (`terraform/bootstrap`): an encrypted, versioned S3 bucket plus a DynamoDB lock table, so state stays safe under concurrent runs.
- **VPC** ([`terraform/modules/vpc`](terraform/modules/vpc)): 2 public + 2 private subnets across 2 AZs, one NAT Gateway shared by both private subnets — a deliberate cost tradeoff for dev (production would run one per AZ). Subnets are pre-tagged for EKS/load-balancer discovery.
- **GitHub Actions OIDC** ([`terraform/modules/iam`](terraform/modules/iam)): CI authenticates to AWS with short-lived OIDC tokens instead of long-lived keys sitting in GitHub Secrets.
- **ECR** ([`terraform/modules/ecr`](terraform/modules/ecr)): immutable image tags, vulnerability scanning on push, and a lifecycle policy so image storage doesn't grow forever.
- **CI pipeline** (`.github/workflows/ci.yml`): every push to `main` and every pull request against it builds all three service images (`api`, `worker`, `remediator`) and scans them with Trivy. Any HIGH or CRITICAL vulnerability with a fix available fails the build. Unfixed CVEs are excluded on purpose (`ignore-unfixed: true`) — gating on vulnerabilities that have no upstream patch yet just trains people to bypass the gate instead of fixing anything. AWS credentials are only issued on pushes to `main`, never on a PR run, so a malicious PR can't steal real credentials even if it tried. Bumping the deployed image tag is a manual commit rather than an automated CI step — a deliberate choice to avoid the added complexity of giving CI write access to the repo, and to keep a human in the loop before any new image actually goes live.
- **EKS** ([`terraform/modules/eks`](terraform/modules/eks)): a managed control plane, a 2x t3.large node group (sized for the pod-per-node ceiling — see [Known Gotchas](docs/known-gotchas.md)), and core add-ons (VPC CNI, CoreDNS, kube-proxy, EBS CSI) all through Terraform. EBS CSI runs on IAM Roles for Service Accounts (IRSA) alone; VPC CNI needs a node-level policy to bootstrap before its own IRSA role takes over.
- **Sample app** (`app/`, `kubernetes/helm-charts/railhead-app`): a small FastAPI service backed by Postgres, plus a worker that exercises the API on a loop. On first install, the API briefly crash-loops while Postgres is still starting — nothing waits for DB readiness yet — then self-recovers within about a minute. Known, not hidden; an `initContainer` is the obvious fix, just not built.
- **GitOps** ([`terraform/modules/argocd`](terraform/modules/argocd)): ArgoCD deploys the app from a git-tracked `Application`, with `selfHeal` and `prune` on — no one runs `helm install` by hand anymore. Proven, not just configured: scaling the API to 0 by hand was reverted back to 2 replicas in about a second, with zero human involvement.
- **Metrics** (`terraform/modules/argocd`, kube-prometheus-stack): Prometheus and Grafana, deployed as their own ArgoCD Application. The API exposes `/metrics` via `prometheus-fastapi-instrumentator`. Dashboards are code — JSON committed to the repo, auto-loaded by Grafana's sidecar — so wiping the Grafana PVC doesn't lose them.
- **Logs** (`terraform/modules/argocd`, Loki + Grafana Alloy): Loki aggregates logs cluster-wide (S3-backed, 7-day retention), shipped by Alloy as a DaemonSet. Alloy over the older Promtail specifically because Promtail hit end-of-life in March 2026. Grafana picks up Loki the same way it picks up dashboards — a labeled ConfigMap.
- **Alerting** (`terraform/modules/argocd`, Alertmanager): two SLOs — 99% availability (5xx only; a bad client request isn't a service failure, so 4xx doesn't count) and 95% of requests under 300ms. All five rules exclude `/health` and `/metrics`: neither is user traffic, and both dilute the denominator in the direction that hides problems. Probe traffic outnumbers real traffic roughly 6:1 and never fails. `/metrics` is worse in a subtler way — it is scraped on a fixed interval, so as real throughput collapses under fault the scrape share *rises*, weakening the signal exactly when it is needed. That was measured, not assumed, and cost 8 minutes of detection time before it was fixed ([Chaos Engineering](#chaos-engineering)). Each gets the burn-rate math the Google SRE Workbook recommends: a fast/critical rule (14.4x the sustainable rate, sustained over both a 1-hour and 5-minute window) and a slower/warning one (6x, over 6 hours and 30 minutes). Alertmanager posts both severities to one Slack channel, color- and emoji-coded so you can tell them apart at a glance. Proven live: I took Postgres offline, threw a burst of traffic at the API, and watched the alert land in Slack. There's a [runbook](docs/runbooks/api-high-error-rate.md) for what to do when it fires.
- **Automated remediation** (`app/remediator`, `kubernetes/helm-charts/railhead-remediator`): a Flask webhook receiver that Alertmanager posts to. On a per-pod error-rate alert, it quarantines the pod — relabeling it out of both the Service and ReplicaSet selectors in one patch, so traffic stops and a healthy replacement is created immediately, while the broken pod keeps running for inspection and is deleted after a TTL. Guarded against acting where it shouldn't: it refuses if quarantining would leave no pod serving traffic, and after 3 quarantines in 15 minutes. A third guard, meant to refuse when several pods alert at once, **was disproven by chaos testing** — it is documented as broken rather than quietly fixed, because that is what "verified" has to mean. Full reasoning and the measured failure in the dedicated section below.
- **Chaos engineering** ([`terraform/modules/chaos-mesh`](terraform/modules/chaos-mesh), [`chaos/`](chaos/)): Chaos Mesh 2.8.4, used to inject real faults into the running cluster and measure what the platform catches on its own. Deployed by Terraform rather than as an ArgoCD Application — its CRDs and admission webhooks defeat ArgoCD's sync ordering ([Known Gotchas](docs/known-gotchas.md) #29). Experiment manifests are hand-applied and deleted afterwards, never deployed state. Results below.

## Cost approach

Built and torn down incrementally, not left running. The expensive resources — EKS control plane, node group, NAT Gateway — come down at the end of every session and go back up at the start of the next. **Neither direction is a single command.** Teardown is a six-step documented sequence: the ArgoCD Applications and then the namespaces they deployed into must be deleted by hand *before* Terraform runs, because deleting an Application does not delete what it created — skip that and the EBS volumes orphan and bill indefinitely. Only step 5 is a `terraform destroy`. The rebuild is longer still: three targeted passes plus a manual CRD bootstrap, because a single apply can't sequence ArgoCD's CRDs ahead of the resources that require them. Both are written up step by step, with expected output and a ten-check orphan sweep: [teardown](docs/teardown-sequence.md), [rebuild](docs/rebuild-sequence.md). Together they run about $0.31/hour at list price, so a working session costs roughly a dollar instead of the ~$227/month they'd cost left running.

What persists between sessions is deliberately the cheap half: the S3/DynamoDB state backend, the IAM roles, the ECR repositories, and the S3 bucket holding Loki's log chunks. That's well under $1/month in total, almost all of it ECR image storage — worth paying so nothing has to be rebuilt from scratch. A $50/month budget alarm and a zero-spend alert back the whole thing up. Both live at the account level rather than in this repo's Terraform — deliberately, so that tearing down the workload can never take the spend guardrails down with it.

## Automated Remediation

**The failure.** `railhead-api` runs 2 replicas behind one Service. One pod's Postgres connection pool got corrupted under load: `psycopg2`'s `SimpleConnectionPool` isn't thread-safe, and FastAPI calls it from a threadpool. Every `getconn()` started raising, so that pod returned 500 on every `/items` request — half the Service's traffic — while still reporting `1/1 Running` and `Ready`. Kubernetes never noticed, because the readiness probe hits `/health`, which deliberately doesn't touch the database — checking a shared dependency in a readiness probe fails every replica at once, turning partial degradation into a total outage.

**Why a better probe wouldn't help.** Say the probe did check Postgres. The pod would fail readiness and stop receiving traffic, but it would still match the ReplicaSet's selector and still count toward the replica total. No replacement would ever be created, and the service would sit at half capacity indefinitely. Dropping the pod out of the *selector* is the only thing that actually restores capacity.

**What the remediator does.** On a per-pod error-rate alert it patches the pod's `app` label to `railhead-api-quarantined`. That one change hits two selectors at once: the Service stops routing to it, and the ReplicaSet sees itself short a pod and creates a healthy one. The broken pod keeps running, orphaned, so it can still be inspected — then it's deleted after a 60-minute TTL.

**Three guards — and one of them does not work.** It refuses to act if quarantining would leave nothing serving traffic, and after 3 quarantines in 15 minutes (a bad deployment, not one bad pod). Every refusal is posted to Slack. A third guard is meant to refuse when several pods are alerting at once — a shared failure, where any replacement would be equally broken. **Chaos testing proved it does not hold.** Both api pods were quarantined 300s apart with zero refusals, during exactly the outage the guard exists to prevent.

**Why it failed.** The guard reads a single webhook payload and counts pods whose alert is still `firing` in it. Two things break that. Alertmanager's `group_interval` is 5 minutes and the two pods' `for: 2m` timers desynchronised by 65s, so they arrived in *separate* payloads. And quarantining the first pod drops it out of the Service — the ServiceMonitor scrapes *through* the Service, so Prometheus stops scraping it and its alert **resolves**. By the time the second payload arrived, the first pod was no longer firing and the second genuinely was the only one. **The remediator's own action erases the evidence its next decision depends on.**

The synthetic guard test passed because a hand-written payload contained both pods at once. Real Alertmanager never sends that payload. The code was correct and the test was wrong — which is the more transferable lesson.

**What held.** `MIN_REMAINING_READY` refused at every decision point: `readyReplicas` never reached 0, so this was degradation, not an outage. Defence in depth held at the last layer. What failed was the layer meant to prevent churn.

**The fix — recommended, not implemented.** Count pods *recently acted on* rather than pods *currently firing*, using the 15-minute history the remediator already keeps for `MAX_QUARANTINES`. It stays unimplemented on purpose: the measured behaviour is the artifact of this project, and a defect that gets silently patched teaches nobody anything. Mechanism in full: [Known Gotchas](docs/known-gotchas.md) #32 and the [chaos scorecard](docs/week7-chaos-scorecard.md).

```mermaid
flowchart LR
    api[railhead-api pod] -->|/metrics| prom[Prometheus]
    prom -->|one pod over 50% 5xx| am[Alertmanager]
    am -->|notify| slack([Slack])
    am -->|webhook| rem[remediator]
    rem -->|patch app label| api
    rem -->|evidence block| slack
```

Both arrows out of Alertmanager come from a *single* receiver: every alert reaches the remediator exactly the way it reaches Slack. What's safe to act on is decided in `remediate.py` (`AUTO_REMEDIATE_ALERTS`), not in Alertmanager's routing tree — so changing it is one line in one place, rather than two configs that can drift apart.

**Proven live.** A real pod's DNS was broken and its Postgres connections killed from the server side, producing genuine 500s while `/health` stayed green. The alert fired, the pod was quarantined, a replacement was scheduled, and an untouched control pod confirmed the fault stayed isolated. The fault-injection method is recorded in [`docs/remediator-t2-trigger-validation.md`](docs/remediator-t2-trigger-validation.md); the quarantine itself is in the screenshots below.

**What it doesn't do.** This stops the bleeding, not the disease: it restores capacity and preserves evidence, but doesn't fix Postgres or the network. Detection takes **~5 minutes** end to end (scrape interval, rate window, alert hold, Alertmanager grouping) — measured at **5m46s** against a network partition. It was **13m52s** until chaos testing found `/metrics` diluting the alert's denominator; that story is in [Chaos Engineering](#chaos-engineering) below, and it is a good illustration that this floor holds only while the denominator is honest. A service mesh could eject a bad endpoint faster, but would destroy the evidence doing it.

## Chaos Engineering

Before this, the remediator had only ever been validated against a fault built by hand to trigger it. That proves the code path runs. It proves nothing about how the system behaves when a failure arrives on its own terms. **Chaos engineering exists to find where a system does not do what its design says — before a real incident finds it instead.**

Two scenarios were chosen to test the remediator in both directions, because a remediation system has two correct behaviours and only one is usually tested: it must **act** on one bad pod, and **refuse** when the shared dependency is down, since there every replacement inherits the same fault. A third check pointed the same question at the monitoring itself. Predictions were written down before each run and are not edited afterwards.

| | Fault | Analogue | Predicted | Measured |
|---|---|---|---|---|
| 1 | Partition one api pod from Postgres | Replica isolated from its database | Auto-remediated | **Auto-remediated. Denominator defect found in the alert, fixed, re-measured: 13m52s → 5m46s** |
| 2 | Postgres removed under both api pods | Database backend outage | Guard refuses | **Guard did not engage. Both pods quarantined — no outage** |
| 3 | Remediator held down 10 min | Monitoring agent outage | Needed a human | **Undetected** |

**None of it was findable by reading the code.** Two independent design reviews predicted scenario 2 would fail, and **both named the wrong mechanism** — each blamed Alertmanager's grouping, which worked correctly throughout.

### Scenario 1 — worked, and surfaced a defect that was then fixed

The remediator handled a fault it was never tuned for. It identified the partitioned pod, quarantined it **12s** after the alert fired, and had a replacement serving traffic **~30s** later, leaving the broken pod running for inspection; the sibling never alerted. Failure latency measured **5.10s / 5.01s / 5.01s** — precisely `connect_timeout=5`, confirming the 5xx came from failed *new* connections.

The find was in the alert beneath it. `/metrics` sat in the denominator at **~45%**, holding the error ratio oscillating **0.471–0.550** across a 0.5 threshold with a ceiling of **~0.51** — a **2% margin** — and one PENDING period was **abandoned** mid-count. Detection took **13m52s**; on a shorter fault it would not have fired at all.

Excluding `/metrics` from all five rules and re-running the same scenario: **5m46s**, no abandoned PENDING, ratio pinned at **1.0**. `/metrics` is scraped on a fixed interval while `/items` throughput collapses under fault, so the scrape share rises exactly when the alert needs it lowest. Find, fix, re-measure — the loop the exercise exists to run.

### Scenario 2 — the guard did not engage

Both api pods were quarantined **300s apart** with **zero refusals**, during the shared outage the guard exists to prevent. Cause: a **self-erasing evidence loop** — quarantining the first pod drops it from the Service, so Prometheus stops scraping it and its alert resolves, leaving the second looking like a lone failure. Dissected under [Automated Remediation](#automated-remediation) above and in [gotcha #32](docs/known-gotchas.md).

**It cost no outage.** `readyReplicas` traced **1,1,1,1,2,2,1,2,2,2** and never reached 0; `MIN_REMAINING_READY` refused every action that would have emptied the Service, and `MAX_QUARANTINES = 3 / 15min` would have stopped a third. The layer preventing churn failed; the layer preventing an outage held. That is defence in depth doing its job.

### Check 3 — a blind spot in the monitoring itself

Ten minutes with the remediator `0/1` Ready, zero endpoints, `CrashLoopBackOff`, **8 restarts** — and the CloudWatch alarm never left `OK`, because `service_number_of_running_pods` counts pod **phase, not readiness**, and reported **`1.0` every minute**. Detail and the fix tradeoff: [AWS-native monitoring](#aws-native-monitoring) below.

**One analysis correction, recorded.** The burn-rate SLO alerts were predicted to need 45 min – 2 h; they fired in **8 minutes**. The prediction used the *latency* SLO's threshold (0.72) instead of *availability*'s (0.144), and assumed a 6-hour `rate()` window holds six hours of history — false on a cluster rebuilt 12 minutes earlier.

### What the exercise produced

One component validated against an untuned fault. One defect found, mechanism understood down to the 65s timer desynchronisation, fix identified. One monitoring blind spot found before it mattered. One alert defect fixed and re-measured.

Only the last was applied. The rest stay recommendations on purpose: the measured behaviour is the artifact, and a guard that silently starts working — with no record of why it didn't — teaches nobody anything.

Full numbers: [`docs/week7-chaos-scorecard.md`](docs/week7-chaos-scorecard.md). Commands: [`docs/week7-chaos-runbook.md`](docs/week7-chaos-runbook.md). Manifests: [`chaos/`](chaos/).

## AWS-native monitoring

CloudWatch Container Insights runs alongside Prometheus and Grafana rather than replacing them. Two monitoring systems only earn their keep if they see different things — these do.

**What only CloudWatch can see.** AWS operates the control plane. The API server itself is scrapable — this cluster scrapes it — but `kube-scheduler`, `kube-controller-manager`, and etcd are not, which is why those scrape jobs are disabled rather than left permanently down. The audit log is out of reach entirely: Prometheus collects metrics, not a per-request record of which ServiceAccount called what. That record is what makes RBAC checkable from outside the cluster instead of taken on trust.

**Watching the watcher — and the half of it that doesn't work.** The remediator watches `railhead-api`, and nothing watched the remediator: a real gap, since it runs a single replica and a single replica that dies stays dead. Prometheus can't close it — Prometheus and Alertmanager run in the same cluster and can't reliably alert on a failure that takes them down too. A CloudWatch alarm sits outside the cluster and survives what it reports on. That reasoning still holds and is why the alarm lives in CloudWatch.

**The alarm as built closes only half the gap, and chaos testing is what revealed it.** Holding the remediator down for ten minutes left it `0/1` Ready, zero endpoints, `CrashLoopBackOff`, 8 restarts — and the alarm never left `OK`, because `service_number_of_running_pods` counts pods in the **`Running` phase**, not ready ones. It reported `1.0` every minute while the pod was running and useless.

So the alarm detects a remediator that is **gone**, not one **running but broken** — which is how it actually fails: crashloop, deadlock, hung server. Reading the Terraform would never have shown this. `treat_missing_data = "breaching"` remains correct for the case it does cover: a pod that disappears stops publishing rather than reporting zero, and the CloudWatch default would stay silent for exactly that failure.

The honest fix is an external synthetic probe against `/healthz`, keeping the independence that motivated CloudWatch. A readiness-derived Prometheus metric would be accurate but reintroduces the in-cluster dependency the alarm exists to avoid. **Recommended, not implemented** — see gotcha #34.

**Three alarms, no pager.** Remediator down, node disk over 80% (kubelet starts evicting around 90%), and etcd growth past 100 MB against a 27 MB baseline. None of them notify — Alertmanager already owns routing, and a second delivery path is a second thing that can drift.

**Logs stay in Loki.** Container log shipping is off, along with the add-on's own kube-state-metrics and node-exporter, both of which would have duplicated what's already running.

Reusable Logs Insights queries, with captured output, are in [`docs/cloudwatch-logs-insights-queries.md`](docs/cloudwatch-logs-insights-queries.md).

## Known gotchas

Real problems hit while building this, kept in [`docs/known-gotchas.md`](docs/known-gotchas.md) rather than quietly fixed and forgotten.

## Screenshots

I wanted actual proof here, not just claims — so this folder has real `terraform apply`/`destroy` output, AWS Console views, `kubectl`/ArgoCD/Grafana output, and Slack alerts, organized by component under `screenshots/`. I only capture things that don't already have a permanent record somewhere else. The five below are the headline proofs; the rest are grouped by component in the collapsible sections under them.

Self-heal proof: manually scaling the API to 0 via `kubectl` (bypassing git entirely) was detected and reverted back to 2 replicas by ArgoCD, with zero human intervention:
![kubectl events showing ArgoCD self-heal reverting a manual scale-to-zero](screenshots/argocd-selfheal.png)

Real burn-rate alerts arriving in Slack, critical (🔴) and warning (🟡) visually distinct — triggered by deliberately taking Postgres offline and generating a burst of failing requests, not simulated:
![Slack messages showing critical and warning burn-rate alerts with distinct color/emoji](screenshots/slack-burnrate-alert.png)

A real quarantine, triggered by an actual DNS-corruption fault injection, not a synthetic payload — the evidence block shows the pod's own logs at the moment of failure:
![Slack quarantine message with the evidence block from a real fault injection](screenshots/remediator-quarantine-slack.png)

Pods after quarantine: the broken pod relabeled to `railhead-api-quarantined`, its replacement already `Running` alongside the untouched control pod:
![kubectl get pods --show-labels showing the quarantined pod and its replacement](screenshots/remediator-pods-after.png)

The guard failure, caught live: **both** api pods quarantined during a shared-dependency outage, which is exactly what the `multi_pod` guard exists to prevent. This is the most useful artifact in the repo — a defect in my own automation, found by running it rather than by reading it:
![kubectl output showing both api pods quarantined and their replacements during the Postgres outage](screenshots/chaos-scenario2-cascade-state.png)

<details>
<summary><b>VPC (3 screenshots)</b></summary>

VPC module terraform apply output:
![VPC module terraform apply output](screenshots/vpc-apply.png)

VPC resource map (subnets, route tables, NAT Gateway) in the AWS Console:
![VPC resource map in the AWS Console](screenshots/vpc-console.png)

VPC module terraform destroy output:
![VPC module terraform destroy output](screenshots/vpc-destroy.png)

</details>

<details>
<summary><b>IAM / OIDC (2 screenshots)</b></summary>

IAM/OIDC module terraform apply output:
![IAM/OIDC module terraform apply output](screenshots/iam-apply.png)

GitHub Actions IAM role's Trust relationships tab, showing the OIDC condition:
![IAM role trust relationship showing the OIDC condition](screenshots/iam-trust-policy.png)

</details>

<details>
<summary><b>ECR (2 screenshots)</b></summary>

Terraform apply that created the first ECR repository and tightened the GitHub Actions OIDC trust condition from an any-branch wildcard (`repo:Levi-TenshiOps/railhead:*`) to main-branch-only (`repo:Levi-TenshiOps/railhead:ref:refs/heads/main`) — every line of the old policy carries a removal prefix, confirming this is the wildcard being replaced, not left in place. See `iam-trust-policy.png` above for the resulting policy live in the console:
![ECR module terraform apply output](screenshots/ecr-apply.png)

ECR repository settings (immutable tags, scan-on-push), from before the split into three repositories (`railhead-api`, `railhead-worker`, `railhead-remediator`) — the settings shown still apply to all three:
![ECR repository settings](screenshots/ecr-repository.png)

</details>

<details>
<summary><b>EKS (2 screenshots)</b></summary>

EKS module terraform apply output (cluster, node group, and IRSA-backed add-ons):
![EKS module terraform apply output](screenshots/eks-apply.png)

Both managed nodes `Ready`, verified independently via `kubectl`:
![kubectl get nodes showing both managed nodes Ready](screenshots/eks-nodes.png)

</details>

<details>
<summary><b>Sample app (2 screenshots)</b></summary>

All app pods running (`api` ×2, `worker`, Postgres):
![kubectl get pods showing the sample app running](screenshots/app-pods.png)

Worker logs, alternating `GET`/`POST` calls against the API on a fixed interval:
![Worker logs alternating GET/POST calls against the API](screenshots/app-worker-logs.png)

</details>

<details>
<summary><b>GitOps — ArgoCD (3 more screenshots)</b></summary>

Early GitOps state, from 07/17/2026 when only the app and observability Applications existed — both `Healthy` and `Synced`. See the remediation group below for all five Applications as they stand now:
![Both ArgoCD Applications healthy and synced](screenshots/argocd-observability-synced.png)

Full resource tree for the `railhead` Application (API, worker, Postgres StatefulSet, and their supporting resources):
![ArgoCD resource tree for the railhead Application](screenshots/argocd-synced.png)

Mid-incident resource tree from the Grafana PVC-reset troubleshooting session, showing several stale Grafana ReplicaSet revisions while the rollout was still catching up — the debugging process itself, not just the clean end state:
![ArgoCD resource tree mid-troubleshooting during the Grafana PVC-reset incident](screenshots/argocd-debug-resource-tree.png)

</details>

<details>
<summary><b>Observability — metrics (4 screenshots)</b></summary>

Custom `Railhead — API Metrics` dashboard (request rate, p95 latency, and error rate by endpoint):
![Railhead API Metrics Grafana dashboard](screenshots/grafana-api-dashboard.png)

Custom `Railhead — Cluster Health` dashboard (node CPU/memory, pod count by namespace, pod restarts):
![Railhead Cluster Health Grafana dashboard](screenshots/grafana-cluster-dashboard.png)

Dashboard-persistence proof, part 1: a fresh Grafana pod (age 15m, 0 restarts) after a PVC reset that would have wiped any manually-created dashboard:
![Fresh Grafana pod after a PVC reset](screenshots/grafana-dashboards-fresh-pod.png)

Dashboard-persistence proof, part 2: both custom dashboards still present — re-provisioned automatically from the labeled ConfigMaps rather than lost with the old PVC:
![Custom dashboards still present after the PVC reset](screenshots/grafana-dashboards-persisted.png)

</details>

<details>
<summary><b>Observability — logs (1 screenshot)</b></summary>

Grafana Explore, Loki datasource, a live LogQL query pulling real `railhead-api` log lines shipped end-to-end through Alloy → Loki → Grafana:
![Grafana Explore showing live Loki logs from the API pods](screenshots/grafana-loki-explore.png)

</details>

<details>
<summary><b>Automated remediation — 4 more screenshots</b></summary>

All 5 ArgoCD Applications `Synced`/`Healthy` with the remediator deployed:
![ArgoCD showing all 5 Applications Synced and Healthy](screenshots/remediator-argocd-healthy.png)

Guard rails refusing to act across four synthetic payloads: an unknown alert observed, a valid alert missing its pod label, a nonexistent pod, and two pods alerting at once — all correctly refused, none of them touched a label. **Worth reading alongside the chaos results:** the fourth case is the `multi_pod` guard working exactly as designed, and chaos testing later showed real Alertmanager never sends the payload this test sends. The code was right; the test was wrong. That gap between a passing synthetic test and live behaviour is the most useful thing in this repo:
![Slack showing the remediator's guard refusals across four synthetic test payloads](screenshots/remediator-guard-refusal.png)

EndpointSlice after quarantine: only the two healthy pod IPs remain — the quarantined pod's IP is gone:
![EndpointSlice showing only the two healthy pod IPs after quarantine](screenshots/remediator-endpoints-after.png)

Grafana's error-rate panel, showing the fault's entire lifecycle: a clean spike as the fault took hold, holding while the pod kept serving broken traffic, then a sharp drop back to zero the moment quarantine restored capacity:
![Grafana error rate panel showing spike and recovery around the quarantine event](screenshots/remediator-grafana-recovery.png)

</details>

<details>
<summary><b>Chaos engineering (6 screenshots)</b></summary>

The Chaos Mesh dashboard with the scenario 1 NetworkChaos experiment running — the partition between one api pod and Postgres, injected by hand and deleted afterwards:
![Chaos Mesh dashboard showing the api-postgres-partition experiment](screenshots/chaos-mesh-dashboard.png)

The failure mechanism, measured rather than assumed: probed latency of **5.10s / 5.01s / 5.01s** on the partitioned pod — precisely `connect_timeout=5`, confirming the 5xx come from failed *new* connections rather than the pooled one:
![Terminal output showing 5.10s, 5.01s and 5.01s failure latencies against the partitioned pod](screenshots/chaos-scenario1-failure-mechanism.png)

Scenario 1's quarantine in Slack, 12s after the alert fired — against a network partition the remediator was never tuned for:
![Slack message showing the remediator quarantining the partitioned api pod](screenshots/chaos-scenario1-remediator-slack.png)

Labels after that quarantine: `app` rewritten to `railhead-api-quarantined` plus the `railhead.io/quarantined-at` timestamp, which is what drops the pod out of both the Service and the ReplicaSet selector:
![kubectl get pods --show-labels showing the quarantine labels on the partitioned pod](screenshots/chaos-scenario1-quarantined-labels.png)

Scenario 2's grouped alert — both api pods failing at once under the Postgres outage. Alertmanager's grouping worked correctly here; the guard still didn't engage, for reasons in [Chaos Engineering](#chaos-engineering) above:
![Alertmanager showing both api pods grouped in one firing alert](screenshots/chaos-scenario2-grouped-alert.png)

The alert rules as they stand **after** the `/metrics` fix — all five carrying `handler!~"/health|/metrics"`, across all three rule groups, loaded and healthy in Prometheus:
![Prometheus alerts page showing all five railhead rules with the /health and /metrics exclusion](screenshots/railhead-alert-rules.png)

</details>

<details>
<summary><b>AWS-native monitoring — CloudWatch (6 screenshots)</b></summary>

Container Insights overview. The Cluster and Service rows now read `2 OK` and `1 OK`; the other resource types have no alarms targeting them, so they still show "No alarms detected":
![CloudWatch Container Insights overview for the railhead-dev cluster](screenshots/cloudwatch-container-insights.png)

All three alarms in `OK`, none carrying a notification action:
![CloudWatch alarms list showing all three railhead-dev alarms OK](screenshots/cloudwatch-alarms.png)

Both log groups at 1-day retention — the fix for never-expiring groups outliving `terraform destroy`. Terraform owns them, which is what makes the retention stick and what removes them at teardown:
![CloudWatch log groups showing both railhead groups at 1 day retention](screenshots/cloudwatch-log-groups-retention.png)

`apiserver_storage_size_bytes` graphed — etcd object storage, flat at 28.27 MB across the window, and the metric the growth alarm watches:
![CloudWatch metrics graph of apiserver_storage_size_bytes](screenshots/cloudwatch-apiserver-storage.png)

Least-privilege, checked from outside the cluster. The remediator's `Role` grants six verb/resource combinations — `get`/`list`/`patch`/`delete` on pods, `get` on `pods/log`, `get` on deployments — and the audit log shows exactly one was ever exercised: `list pods`, twice, in `railhead`. It's namespaced rather than a `ClusterRole`, so `kube-system` and `argocd` are out of reach, and it grants no `create`, no `watch`, no `pods/exec`, and nothing for secrets, configmaps, nodes, or RBAC:
![Logs Insights query showing the remediator ServiceAccount made only list-pods calls](screenshots/cloudwatch-logs-insights-least-privilege.png)

Top API-server callers over a 3-hour window. `kube-scheduler` and `kube-controller-manager` appear with thousands of calls each, and neither is scraped by Prometheus here — AWS exposes no metrics endpoint for them:
![Logs Insights query ranking API server callers by request count](screenshots/cloudwatch-logs-insights-top-callers.png)

</details>
