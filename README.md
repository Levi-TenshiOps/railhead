> **Status:** Weeks 1-6 of 8 complete — infrastructure, CI/CD, GitOps, observability (metrics, logs, alerting), and automated remediation are all done and verified. Actively in development: chaos engineering (Week 7), then final polish (Week 8).

# Railhead — Production-Grade SRE Platform on AWS

Railhead is a portfolio project built to prove something specific: that I can run the full lifecycle of a production service on AWS, not just describe it in an interview. It provisions its own infrastructure with Terraform, deploys itself through GitOps with ArgoCD, and now monitors itself with real SLOs and burn-rate alerting — verified end-to-end against a live AWS account, not just configured and left untested.

Automated remediation is already built: when a pod is serving majority errors while its siblings stay healthy, a script quarantines it — relabeling it out of the Service and ReplicaSet selectors so traffic stops and a healthy replacement is created, while the broken pod keeps running for inspection. One piece is still ahead: chaos engineering, deliberately injecting the kinds of failures I've actually diagnosed running production VxRail/vSAN clusters at Dell — storage latency, DNS misconfiguration, cert expiry, disk pressure — and measuring how much of that the system catches on its own.

Full status: see Architecture below for what's built, Roadmap for what's left.

## Why "Railhead"

A railhead is where a rail line physically ends and cargo transfers onward to its next mode of transport — that's the metaphor: code "arrives" from git here and gets carried into running infrastructure. It's also a nod to VxRail, the hyperconverged platform I've supported in production for years. The name sits at the intersection of both.

## Architecture — what's built so far

Everything below is live and verified against a real AWS account — nothing here is aspirational.

```mermaid
flowchart LR
    dev([Developer]) -->|git push| gh[GitHub]
    gh -->|OIDC, no static keys| ci[Actions: build + Trivy gate]
    ci -->|push image| ecr[(ECR)]
    gh -->|watches main| argo[ArgoCD: selfHeal + prune]
    argo -->|deploys| eks[EKS cluster]
    ecr -.->|image pull| eks
```

Two paths lead into the cluster and they never cross: container images travel through GitHub Actions into ECR, while *configuration* travels through ArgoCD. CI holds no cluster credentials and never runs `kubectl`; ArgoCD holds no AWS credentials. Neither one can do the other's job, which is the point.

- **Terraform state backend** (`terraform/bootstrap`): an encrypted, versioned S3 bucket plus a DynamoDB lock table, so state stays safe under concurrent runs.
- **VPC** (`terraform/modules/vpc`): 2 public + 2 private subnets across 2 AZs, one NAT Gateway shared by both private subnets — a deliberate cost tradeoff for dev (production would run one per AZ). Subnets are pre-tagged for EKS/load-balancer discovery.
- **GitHub Actions OIDC** (`terraform/modules/iam`): CI authenticates to AWS with short-lived OIDC tokens instead of long-lived keys sitting in GitHub Secrets.
- **ECR** (`terraform/modules/ecr`): immutable image tags, vulnerability scanning on push, and a lifecycle policy so image storage doesn't grow forever.
- **CI pipeline** (`.github/workflows/ci.yml`): every push and pull request builds all three service images (`api`, `worker`, `remediator`) and scans them with Trivy. Any HIGH or CRITICAL vulnerability with a fix available fails the build. Unfixed CVEs are excluded on purpose (`ignore-unfixed: true`) — gating on vulnerabilities that have no upstream patch yet just trains people to bypass the gate instead of fixing anything. AWS credentials are only issued on pushes to `main`, never on a PR run, so a malicious PR can't steal real credentials even if it tried. Bumping the deployed image tag is a manual commit rather than an automated CI step — a deliberate choice to avoid the added complexity of giving CI write access to the repo, and to keep a human in the loop before any new image actually goes live.
- **EKS** (`terraform/modules/eks`): a managed control plane, a 2x t3.large node group (sized for the pod-per-node ceiling — see [Known Gotchas](docs/known-gotchas.md)), and core add-ons (VPC CNI, CoreDNS, kube-proxy, EBS CSI) all through Terraform. EBS CSI runs on IAM Roles for Service Accounts (IRSA) alone; VPC CNI needs a node-level policy to bootstrap before its own IRSA role takes over.
- **Sample app** (`app/`, `kubernetes/helm-charts/railhead-app`): a small FastAPI service backed by Postgres, plus a worker that exercises the API on a loop. On first install, the API briefly crash-loops while Postgres is still starting — nothing waits for DB readiness yet — then self-recovers within about a minute. Known, not hidden; an `initContainer` is the obvious fix, just not built.
- **GitOps** (`terraform/modules/argocd`): ArgoCD deploys the app from a git-tracked `Application`, with `selfHeal` and `prune` on — no one runs `helm install` by hand anymore. Proven, not just configured: scaling the API to 0 by hand was reverted back to 2 replicas in about a second, with zero human involvement.
- **Metrics** (`terraform/modules/argocd`, kube-prometheus-stack): Prometheus and Grafana, deployed as their own ArgoCD Application. The API exposes `/metrics` via `prometheus-fastapi-instrumentator`. Dashboards are code — JSON committed to the repo, auto-loaded by Grafana's sidecar — so wiping the Grafana PVC doesn't lose them.
- **Logs** (`terraform/modules/argocd`, Loki + Grafana Alloy): Loki aggregates logs cluster-wide (S3-backed, 7-day retention), shipped by Alloy as a DaemonSet. Alloy over the older Promtail specifically because Promtail hit end-of-life in March 2026. Grafana picks up Loki the same way it picks up dashboards — a labeled ConfigMap.
- **Alerting** (`terraform/modules/argocd`, Alertmanager): two SLOs — 99% availability (5xx only; a bad client request isn't a service failure, so 4xx doesn't count) and 95% of requests under 300ms. Each gets the burn-rate math the Google SRE Workbook recommends: a fast/critical rule (14.4x the sustainable rate, sustained over both a 1-hour and 5-minute window) and a slower/warning one (6x, over 6 hours and 30 minutes). Alertmanager posts both severities to one Slack channel, color- and emoji-coded so you can tell them apart at a glance. Proven live: I took Postgres offline, threw a burst of traffic at the API, and watched the alert land in Slack. There's a runbook (`docs/runbooks/api-high-error-rate.md`) for what to do when it fires.
- **Automated remediation** (`app/remediator`, `kubernetes/helm-charts/railhead-remediator`): a Flask webhook receiver that Alertmanager posts to. On a per-pod error-rate alert, it quarantines the pod — relabeling it out of both the Service and ReplicaSet selectors in one patch, so traffic stops and a healthy replacement is created immediately, while the broken pod keeps running for inspection and is deleted after a TTL. Guarded against acting where it shouldn't: refuses if quarantining would leave no pod serving traffic, if multiple pods are alerting at once (a shared failure, not one bad pod), or if it's already quarantined 3 pods in 15 minutes. Full reasoning in the dedicated section below.

## Roadmap

### Week 7 — Chaos Engineering
- Chaos Mesh for orchestrating experiments
- Chaos scenarios modeled on real production incidents diagnosed at Dell (storage latency, DNS misconfiguration, cert expiry, disk pressure/RAID, NTP/clock drift) — not generic random pod-killing
- A self-healing scorecard: for each injected failure, record whether it self-healed automatically, was caught by Week 6's auto-remediation, or needed a human
- Written postmortems for each simulated incident
- Optional, revisit at the time: a small downstream service the API calls (tests graceful degradation vs. cascading failure), which would also be the point where distributed tracing finally has something real to show

### Week 8 — Polish, Security/Cost Pass, and Demo
- Security pass: network policies, IAM least-privilege review, secrets hygiene
- Cost pass: right-sizing, revisit Spot instances for nodes
- Decide how to deliberately use remaining AWS credits on something higher-value (candidates already on record: temporary production-scale demo config, EFK built alongside Loki as a comparison, Karpenter, or a multi-region DR simulation stretch)
- Final README pass, architecture diagram, clean commit history
- Demo video

## Cost approach

Built and torn down incrementally, not left running. The expensive resources — the EKS control plane, the node group, and the NAT Gateway — are destroyed at the end of every session (`terraform destroy -target=module.eks -target=module.vpc`) and rebuilt at the start of the next. Teardown is one command; the rebuild is not — it takes three targeted Terraform passes plus a manual CRD bootstrap, for ordering reasons written up in [`docs/rebuild-sequence.md`](docs/rebuild-sequence.md). Together they run about $0.31/hour at list price, so a working session costs roughly a dollar instead of the ~$227/month they'd cost left running.

What persists between sessions is deliberately the cheap half: the S3/DynamoDB state backend, the IAM roles, the ECR repositories, and the S3 bucket holding Loki's log chunks. That's about $0.25/month in total, almost all of it ECR image storage — worth paying so nothing has to be rebuilt from scratch. A $50/month budget alarm and a zero-spend alert back the whole thing up. Both live at the account level rather than in this repo's Terraform — deliberately, so that tearing down the workload can never take the spend guardrails down with it.

## Automated Remediation

`railhead-api` runs 2 replicas behind one Service. Under load, one pod's `psycopg2.pool.SimpleConnectionPool` — not thread-safe, but used directly under FastAPI's threadpool — got its internal bookkeeping corrupted: every `getconn()` started raising, and the pod served ~50% errors while still showing `1/1 Running` and `Ready`. Its readiness probe hits `/health`, which is deliberately database-free (checking a shared dependency there would fail every replica at once, turning partial degradation into a total outage), so Kubernetes never noticed.

A better probe wouldn't have helped either: a pod failing readiness still matches the ReplicaSet's selector and still counts toward the replica total, so no replacement gets created — the service would just run at half capacity indefinitely. The only thing that reliably fixes this is changing the pod's label so it drops out of the ReplicaSet's selector entirely.

On a per-pod error-rate alert, `railhead-remediator` (`app/remediator`) does exactly that: it patches the pod's `app` label to `railhead-api-quarantined`. That one change drops it out of both the Service selector (traffic stops) and the ReplicaSet selector (a healthy replacement is created) in a single call. The broken pod keeps running, orphaned, for inspection, and is deleted after a 60-minute TTL. Three guards keep it from acting where it shouldn't: it refuses if quarantining would leave no pod serving traffic, if multiple pods are alerting at once (a shared failure, not one bad pod), or after 3 quarantines in 15 minutes (a bad deployment, not one bad pod).

```mermaid
flowchart LR
    api[railhead-api pod] -->|/metrics| prom[Prometheus]
    prom -->|one pod over 50% 5xx| am[Alertmanager]
    am -->|notify| slack([Slack])
    am -->|webhook| rem[remediator]
    rem -->|patch app label| api
    rem -->|evidence block| slack
```

Both arrows out of Alertmanager come from a *single* receiver — every critical and warning alert reaches the remediator's webhook exactly the way it reaches Slack. What is actually safe to act on is decided in `remediate.py` (`AUTO_REMEDIATE_ALERTS`), not in Alertmanager's routing tree, so widening or narrowing what gets auto-fixed stays a one-line change in one place instead of two configs that can drift apart.

Proven live, not just written: a real pod's DNS was broken and its Postgres connections terminated from the server side, forcing genuine 500s while `/health` kept passing. The alert fired, the pod was quarantined, a healthy replacement was scheduled, and the untouched control pod proved the fault stayed isolated. The full step-by-step run — every expected-vs-actual check, including the ones confirming the control pod and the EndpointSlice behaved correctly — is recorded in [`docs/remediator-t2-trigger-validation.md`](docs/remediator-t2-trigger-validation.md).

This stops the bleeding, not the disease — it doesn't fix Postgres or the network, just restores capacity and preserves evidence. Detection takes ~5 minutes end to end (scrape interval, rate window, alert hold, Alertmanager grouping); a service mesh could eject a bad endpoint faster, but would destroy the evidence in the process.

## Known gotchas

Real problems hit while building this, kept in [`docs/known-gotchas.md`](docs/known-gotchas.md) rather than quietly fixed and forgotten.

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

**Automated remediation (pod quarantine)**

All 5 ArgoCD Applications `Synced`/`Healthy` with the remediator deployed:
![ArgoCD showing all 5 Applications Synced and Healthy](screenshots/remediator-argocd-healthy.png)

Guard rails refusing to act: an unknown alert observed, a valid alert missing its pod label, a nonexistent pod, and two pods alerting at once — all correctly refused, none of them touched a label:
![Slack showing the remediator's guard refusals across four synthetic test payloads](screenshots/remediator-guard-refusal.png)

A real quarantine, triggered by an actual DNS-corruption fault injection, not a synthetic payload — the evidence block shows the pod's own logs at the moment of failure:
![Slack quarantine message with the evidence block from a real fault injection](screenshots/remediator-quarantine-slack.png)

Pods after quarantine: the broken pod relabeled to `railhead-api-quarantined`, its replacement already `Running` alongside the untouched control pod:
![kubectl get pods --show-labels showing the quarantined pod and its replacement](screenshots/remediator-pods-after.png)

EndpointSlice after quarantine: only the two healthy pod IPs remain — the quarantined pod's IP is gone:
![EndpointSlice showing only the two healthy pod IPs after quarantine](screenshots/remediator-endpoints-after.png)

Grafana's error-rate panel, showing the fault's entire lifecycle: a clean spike as the fault took hold, holding while the pod kept serving broken traffic, then a sharp drop back to zero the moment quarantine restored capacity:
![Grafana error rate panel showing spike and recovery around the quarantine event](screenshots/remediator-grafana-recovery.png)
