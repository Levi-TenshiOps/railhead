> **Status:** Actively in development — Weeks 1-6 of 8. Infrastructure, CI/CD, GitOps, and observability (metrics, logs, alerting) are done and verified. In progress: automated remediation (finishing Week 6), then chaos engineering (Week 7).

# Railhead — Production-Grade SRE Platform on AWS

Railhead is a portfolio project built to prove something specific: that I can run the full lifecycle of a production service on AWS, not just describe it in an interview. It provisions its own infrastructure with Terraform, deploys itself through GitOps with ArgoCD, and now monitors itself with real SLOs and burn-rate alerting — verified end-to-end against a live AWS account, not just configured and left untested.

Two pieces are still ahead. First, automated remediation: when an alert fires, a script attempts a fix on its own — restart, scale, cordon — and escalates to a human only if it can't resolve things itself. Second, chaos engineering: deliberately injecting the kinds of failures I've actually diagnosed running production VxRail/vSAN clusters at Dell — storage latency, DNS misconfiguration, cert expiry, disk pressure — and measuring how much of that the system catches on its own.

Full status, what's built, and what's still in progress: see the Roadmap below.

## Why "Railhead"

A railhead is where a rail line physically ends and cargo transfers onward to its next mode of transport — that's the metaphor: code "arrives" from git here and gets carried into running infrastructure. It's also a nod to VxRail, the hyperconverged platform I've supported in production for years. The name sits at the intersection of both.

## Architecture — what's built so far

Everything below is live and verified against a real AWS account — nothing here is aspirational.

- **Terraform state backend** (`terraform/bootstrap`): an encrypted, versioned S3 bucket plus a DynamoDB lock table, so state stays safe under concurrent runs.
- **VPC** (`terraform/modules/vpc`): 2 public + 2 private subnets across 2 AZs, one NAT Gateway shared by both private subnets — a deliberate cost tradeoff for dev (production would run one per AZ). Subnets are pre-tagged for EKS/load-balancer discovery.
- **GitHub Actions OIDC** (`terraform/modules/iam`): CI authenticates to AWS with short-lived OIDC tokens instead of long-lived keys sitting in GitHub Secrets.
- **ECR** (`terraform/modules/ecr`): immutable image tags, vulnerability scanning on push, and a lifecycle policy so image storage doesn't grow forever.
- **CI pipeline** (`.github/workflows/ci.yml`): every push and pull request builds both service images (`api`, `worker`) and scans them with Trivy. Any HIGH or CRITICAL vulnerability fails the build — no exceptions, no bypass. AWS credentials are only issued on pushes to `main`, never on a PR run, so a malicious PR can't steal real credentials even if it tried. Bumping the deployed image tag is a manual commit rather than an automated CI step — a deliberate choice to avoid the added complexity of giving CI write access to the repo, and to keep a human in the loop before any new image actually goes live.
- **EKS** (`terraform/modules/eks`): a managed control plane, a 2x t3.medium node group, and core add-ons (VPC CNI, CoreDNS, kube-proxy, EBS CSI) all through Terraform. EBS CSI runs on IAM Roles for Service Accounts (IRSA) alone; VPC CNI needs a node-level policy to bootstrap before its own IRSA role takes over.
- **Sample app** (`app/`, `kubernetes/helm-charts/railhead-app`): a small FastAPI service backed by Postgres, plus a worker that exercises the API on a loop. On first install, the API briefly crash-loops while Postgres is still starting — nothing waits for DB readiness yet — then self-recovers within about a minute. Known, not hidden; an `initContainer` is the obvious fix, just not built.
- **GitOps** (`terraform/modules/argocd`): ArgoCD deploys the app from a git-tracked `Application`, with `selfHeal` and `prune` on — no one runs `helm install` by hand anymore. Proven, not just configured: scaling the API to 0 by hand was reverted back to 2 replicas in about a second, with zero human involvement.
- **Metrics** (`terraform/modules/argocd`, kube-prometheus-stack): Prometheus and Grafana, deployed as their own ArgoCD Application. The API exposes `/metrics` via `prometheus-fastapi-instrumentator`. Dashboards are code — JSON committed to the repo, auto-loaded by Grafana's sidecar — so wiping the Grafana PVC doesn't lose them.
- **Logs** (`terraform/modules/argocd`, Loki + Grafana Alloy): Loki aggregates logs cluster-wide (S3-backed, 7-day retention), shipped by Alloy as a DaemonSet. Alloy over the older Promtail specifically because Promtail hit end-of-life in March 2026. Grafana picks up Loki the same way it picks up dashboards — a labeled ConfigMap.
- **Alerting** (`terraform/modules/argocd`, Alertmanager): two SLOs — 99% availability (5xx only; a bad client request isn't a service failure, so 4xx doesn't count) and 95% of requests under 300ms. Each gets the burn-rate math the Google SRE Workbook recommends: a fast/critical rule (14.4x the sustainable rate, sustained over both a 1-hour and 5-minute window) and a slower/warning one (6x, over 6 hours and 30 minutes). Alertmanager posts both severities to one Slack channel, color- and emoji-coded so you can tell them apart at a glance. Proven live: I took Postgres offline, threw a burst of traffic at the API, and watched the alert land in Slack. There's a runbook (`docs/runbooks/api-high-error-rate.md`) for what to do when it fires.

## Roadmap

### Week 6 — SLOs, Alerting, and Auto-Remediation

**Session A — done:** two SLOs (99% availability, 95% of requests under 300ms), each with a fast/critical and slow/warning burn-rate alert; Alertmanager wired to Slack, color-coded by severity; a written incident runbook. Details above.

**Session B — next up:**
- An automated remediation script: Alertmanager webhook → Python → attempts a fix (restart/scale/cordon) → escalates to a human if it can't resolve the issue itself

## Automated remediation: pod quarantine

### Background

`railhead-api` runs 2 replicas behind a single Service. During load testing we
hit a state where the error rate sat at roughly 50% and stayed there. Both pods
were `1/1 Running` and `Ready`. Restarting the deployment cleared it.

The cause was one pod's connection pool, not the database.
`psycopg2.pool.SimpleConnectionPool` is documented as not thread-safe, and
FastAPI dispatches sync `def` routes through a threadpool. Under concurrency
the pool's internal bookkeeping can be corrupted: connections are checked out
and never recorded as returned, and once the in-use count reaches `maxconn`,
every subsequent `getconn()` raises `PoolError` permanently.

That pool lives in one pod's memory. The other pod was unaffected.

### Why Kubernetes never noticed

The readiness probe hits `/health`:

    @app.get("/health")
    def health():
        return {"status": "ok"}

It returns a hardcoded value and never touches the database. Kubernetes asked
"are you ok?", the pod said yes, and traffic kept being split 50/50.

Kubernetes behaved correctly. The health check answers *"is the web server
running?"* when the useful question is *"can you actually do your job?"*

### Why a better probe isn't enough: it never restores capacity

Making the readiness probe run `SELECT 1` would stop traffic to the broken pod.
It would not replace it.

A pod failing readiness is still `Running` and still matches the ReplicaSet's
label selector. The ReplicaSet's contract is keeping N pods that *match its
selector* — readiness plays no part in that count. So the count stays at 2, no
replacement is created, and the service runs at half capacity indefinitely.

Moving the check to the liveness probe doesn't help either: the container
restarts, hits the same condition, and enters CrashLoopBackOff. You lose the
pod for diagnosis and gain a backoff timer.

**No probe configuration produces a healthy replacement.** Removing the pod
from the ReplicaSet's *selector* does.

### What the script does

On a per-pod error-rate alert, it patches one label on the named pod:

    app: railhead-api  ->  app: railhead-api-quarantined

That label appears in two selectors, so one patch does two things:

- the **Service** selector no longer matches — the pod leaves Endpoints and
  traffic stops
- the **ReplicaSet** selector no longer matches — the ReplicaSet releases the
  pod and creates a replacement, restoring capacity

The broken pod keeps running and is available for inspection. Kubernetes
orphans it completely (the ReplicaSet strips its ownerReference), so nothing
will ever garbage-collect it — the script deletes quarantined pods after a TTL.

### Scope: this stops the bleeding, it does not cure the disease

The script does not fix Postgres, the network, or the application. It stops
users reaching the broken pod, restores capacity, preserves the pod for
diagnosis, and reports what it did. The replacement pod helps only when the
fault was pod-local — a corrupted pool, a node-level network issue.

### Guards

- **Minimum remaining ready** — never quarantine if it would leave no pod
  serving traffic.
- **Multi-pod detection** — if more than one pod is alerting in the same
  Alertmanager payload, this is a shared failure and quarantining is useless
  (every replacement would be equally broken). Refuse and escalate.
- **Quarantine budget** — 3 quarantines in 15 minutes indicates a bad
  deployment rather than one bad pod. Refuse and escalate.

If Postgres itself goes down, all replicas fail together. The multi-pod guard
usually catches this on the first payload; the budget guard is the backstop if
alerts arrive separately.

### Design decision: `/health` stays database-free

Deliberate, not an oversight. A readiness probe that checks a shared dependency
fails every replica simultaneously when that dependency dies, converting
partial degradation into a total outage. Readiness should answer "can I
serve?", not "is everything downstream healthy?".

### Limitation

Detection takes ~5 minutes end to end: scrape interval, 5m rate window,
`for: 2m` hold, Alertmanager grouping delay. A service mesh with outlier
detection would eject a bad endpoint in seconds — but would also destroy the
evidence.

### Week 7 — Chaos Engineering
- Chaos Mesh for orchestrating experiments
- Chaos scenarios modeled on real production incidents diagnosed at Dell (storage latency, DNS misconfiguration, cert expiry, disk pressure/RAID, NTP/clock drift) — not generic random pod-killing
- A self-healing scorecard: for each injected failure, record whether it self-healed automatically, was caught by Week 6's auto-remediation, or needed a human
- Written postmortems for each simulated incident
- Optional, revisit at the time: a small downstream service the API calls (tests graceful degradation vs. cascading failure), which would also be the point where distributed tracing finally has something real to show

### Week 8 — Polish, Security/Cost Pass, and Demo
- Security pass: network policies, IAM least-privilege review, secrets hygiene
- Cost pass: right-sizing, revisit Spot instances for nodes
- Repo made public at Week 5, ahead of the original Week 8 plan, to support active SRE job applications.
- Decide how to deliberately use remaining AWS credits on something higher-value (candidates already on record: temporary production-scale demo config, EFK built alongside Loki as a comparison, Karpenter, or a multi-region DR simulation stretch)
- Final README pass, architecture diagram, clean commit history
- Demo video

## Cost approach

Built and torn down incrementally, not left running. Billable resources — the EKS control plane, the node group, the NAT Gateway — get destroyed at the end of each session (`terraform destroy -target=module.eks -target=module.vpc`) and rebuilt when the next one starts. The state backend, IAM, and ECR cost nothing to leave running, so they persist between sessions — nothing has to be rebuilt from scratch. A $50/month budget alert and a zero-spend safety net back this up. Active development runs for pennies; fully torn down, it's $0/month.

## Screenshots

I wanted actual proof here, not just claims — so this folder has real `terraform apply`/`destroy` output, AWS Console views, `kubectl`/ArgoCD/Grafana output, and Slack alerts, organized by component under `screenshots/`. I only capture things that don't already have a permanent record somewhere else.

**VPC**

VPC module terraform apply output:
![VPC module terraform apply output](screenshots/vpc-apply.png)

VPC resource map (subnets, route tables, NAT Gateway) in the AWS Console:
![VPC resource map in the AWS Console](screenshots/vpc-console.png)

VPC module terraform destroy output:
![VPC module terraform destroy output](screenshots/vpc-destroy.png)

**IAM / OIDC**

IAM/OIDC module terraform apply output:
![IAM/OIDC module terraform apply output](screenshots/iam-apply.png)

GitHub Actions IAM role's Trust relationships tab, showing the OIDC condition:
![IAM role trust relationship showing the OIDC condition](screenshots/iam-trust-policy.png)

**ECR**

ECR module terraform apply output:
![ECR module terraform apply output](screenshots/ecr-apply.png)

ECR repository settings (immutable tags, scan-on-push):
![ECR repository settings](screenshots/ecr-repository.png)

**EKS**

EKS module terraform apply output (cluster, node group, and IRSA-backed add-ons):
![EKS module terraform apply output](screenshots/eks-apply.png)

Both managed nodes `Ready`, verified independently via `kubectl`:
![kubectl get nodes showing both managed nodes Ready](screenshots/eks-nodes.png)

**Sample app**

All app pods running (`api` ×2, `worker`, Postgres):
![kubectl get pods showing the sample app running](screenshots/app-pods.png)

Worker logs, alternating `GET`/`POST` calls against the API on a fixed interval:
![Worker logs alternating GET/POST calls against the API](screenshots/app-worker-logs.png)

**GitOps (ArgoCD)**

Both Applications `Healthy` and `Synced`:
![Both ArgoCD Applications healthy and synced](screenshots/argocd-observability-synced.png)

Full resource tree for the `railhead` Application (API, worker, Postgres StatefulSet, and their supporting resources):
![ArgoCD resource tree for the railhead Application](screenshots/argocd-synced.png)

Self-heal proof: manually scaling the API to 0 via `kubectl` (bypassing git entirely) was detected and reverted back to 2 replicas by ArgoCD, with zero human intervention:
![kubectl events showing ArgoCD self-heal reverting a manual scale-to-zero](screenshots/argocd-selfheal.png)

Mid-incident resource tree from the Grafana PVC-reset troubleshooting session, showing several stale Grafana ReplicaSet revisions while the rollout was still catching up — the debugging process itself, not just the clean end state:
![ArgoCD resource tree mid-troubleshooting during the Grafana PVC-reset incident](screenshots/argocd-debug-resource-tree.png)

**Observability — metrics**

Custom `Railhead — API Metrics` dashboard (request rate, p95 latency, and error rate by endpoint):
![Railhead API Metrics Grafana dashboard](screenshots/grafana-api-dashboard.png)

Custom `Railhead — Cluster Health` dashboard (node CPU/memory, pod count by namespace, pod restarts):
![Railhead Cluster Health Grafana dashboard](screenshots/grafana-cluster-dashboard.png)

Dashboard-persistence proof, part 1: a fresh Grafana pod (age 15m, 0 restarts) after a PVC reset that would have wiped any manually-created dashboard:
![Fresh Grafana pod after a PVC reset](screenshots/grafana-dashboards-fresh-pod.png)

Dashboard-persistence proof, part 2: both custom dashboards still present — re-provisioned automatically from the labeled ConfigMaps rather than lost with the old PVC:
![Custom dashboards still present after the PVC reset](screenshots/grafana-dashboards-persisted.png)

**Observability — logs**

Grafana Explore, Loki datasource, a live LogQL query pulling real `railhead-api` log lines shipped end-to-end through Alloy → Loki → Grafana:
![Grafana Explore showing live Loki logs from the API pods](screenshots/grafana-loki-explore.png)

**Alerting**

Real burn-rate alerts arriving in Slack, critical (🔴) and warning (🟡) visually distinct — triggered by deliberately taking Postgres offline and generating a burst of failing requests, not simulated:
![Slack messages showing critical and warning burn-rate alerts with distinct color/emoji](screenshots/slack-burnrate-alert.png)
