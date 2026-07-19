# Railhead — Production-Grade SRE Platform on AWS

Railhead is an end-to-end reliability engineering platform: infrastructure as code → deployment → observability → self-healing → human escalation, built and operated on AWS. It exists to demonstrate the full lifecycle a production SRE actually owns, not just a single layer of it. The differentiator is the chaos engineering component — failure scenarios modeled directly on real production incidents I've diagnosed running Dell VxRail/vSAN clusters (storage layer degradation, node isolation, resync storms), rather than generic random-pod-killing — paired with a self-healing scorecard that measures what percentage of injected failures resolve automatically versus require human escalation.

## Why "Railhead"

A railhead is the point where a rail line physically ends and cargo transfers onward to its next mode of transport. That's the metaphor: this platform is where code "arrives" from git and gets distributed onward into running infrastructure. It's also a deliberate nod to VxRail, the hyperconverged infrastructure platform I've supported in production for several years — the name sits at the intersection of both.

## Architecture — what's built so far

Everything below exists and has been applied/verified against a live AWS account. Nothing in this section is aspirational.

- **Terraform state backend** (`terraform/bootstrap`): an S3 bucket (versioned, AES256-encrypted, all public access blocked) and a DynamoDB table for state locking, so Terraform state itself is durable and safe for concurrent runs.
- **VPC** (`terraform/modules/vpc`): 2 public + 2 private subnets across 2 AWS Availability Zones, an Internet Gateway, and a single NAT Gateway shared by both private subnets (a deliberate cost/resilience tradeoff for a dev environment — production would run one NAT Gateway per AZ). Subnets are pre-tagged for future EKS/load-balancer auto-discovery.
- **GitHub Actions OIDC federation** (`terraform/modules/iam`): keyless CI/CD authentication — GitHub Actions assumes a scoped IAM role via short-lived OIDC tokens instead of long-lived access keys sitting in GitHub Secrets.
- **ECR** (`terraform/modules/ecr`): container image repositories with immutable tags (a pushed tag can never be silently overwritten) and vulnerability scan-on-push enabled, plus a lifecycle policy to keep image storage from growing unbounded.
- **CI pipeline** (`.github/workflows/ci.yml`): every push and pull request builds both service images (`api`, `worker`) and scans them with Trivy (HIGH/CRITICAL severities, build fails on unfixed findings). Only pushes to `main` go on to authenticate to AWS (via the OIDC role above) and push to ECR — pull request runs never request cloud credentials at all, so a crafted build step in a PR has no credentials to exfiltrate. Honest note: bumping the deployed image tag in the Helm chart's `values.yaml` is currently a manual commit after a successful push, not yet wired into CI.
- **EKS** (`terraform/modules/eks`): a managed Kubernetes cluster — control plane plus a managed node group (2x t3.medium, on-demand) — with core add-ons (vpc-cni, coredns, kube-proxy, aws-ebs-csi-driver) managed directly through Terraform. The EBS CSI driver's addon runs on IAM Roles for Service Accounts (IRSA) alone; the VPC CNI addon layers an IRSA role on top of a node-level baseline policy it needs to bootstrap before the pod-scoped role can take over.
- **Sample app** (`app/`, `kubernetes/helm-charts/railhead-app`): a minimal FastAPI service (`railhead-api`) backed by Postgres (via the Bitnami Helm chart as a dependency, on a dedicated `gp3` EBS volume) and a worker process that exercises the API on a fixed interval. Honest note: on first install, the API pods briefly crash-loop while Postgres is still starting, since nothing yet waits explicitly for DB readiness; they self-recover within about a minute once Postgres is up. Observed and understood, not hidden — an `initContainer` that waits for Postgres is a natural fix, just not built yet.
- **GitOps deployment** (`terraform/modules/argocd`): ArgoCD manages the sample app's deployment via a git-tracked `Application` resource pointed at this repo's Helm chart, with automated sync (`prune: true`, `selfHeal: true`) — no human runs `helm install`/`upgrade` anymore. The self-heal behavior is verified, not just configured: manually scaling the API deployment to 0 via `kubectl` (bypassing git entirely) was detected and reverted back to the git-declared 2 replicas by ArgoCD in about a second, with zero human intervention.
- **Observability — metrics** (`terraform/modules/argocd`, kube-prometheus-stack): Prometheus + Grafana, deployed as its own ArgoCD `Application` alongside the app. `railhead-api` is instrumented with `prometheus-fastapi-instrumentator`, exposing a `/metrics` endpoint scraped via a dedicated ServiceMonitor. Dashboards are provisioned as code — JSON committed to this repo, loaded into labeled ConfigMaps, and auto-discovered by Grafana's sidecar — so a Grafana PVC wipe doesn't lose them; they're re-provisioned automatically on next start.
- **Observability — logs** (`terraform/modules/argocd`, Loki + Grafana Alloy): Loki (SingleBinary mode, S3-backed chunk storage, 7-day retention) aggregates logs cluster-wide, shipped by Grafana Alloy running as a DaemonSet. Alloy was chosen over the older Promtail specifically because Promtail reached end-of-life in March 2026 and is no longer maintained. Grafana picks up Loki as a datasource through the same sidecar-ConfigMap mechanism used for dashboards, just watching a `grafana_datasource` label instead of `grafana_dashboard`.

### Planned, not yet built

The following are designed but do not exist in this repo yet:

- **Distributed tracing**
- **Chaos engineering scenarios**
- **Self-healing automation and scorecard**

## Cost approach

This project is built and torn down incrementally rather than left running continuously. Billable resources — the EKS control plane, the 2x t3.medium managed node group, and the shared NAT Gateway — are destroyed at the end of each working session via a targeted `terraform destroy -target=module.eks -target=module.vpc`, and only recreated when the next session picks back up. The Terraform state backend and the IAM/ECR resources (including the Loki S3 bucket, which is deliberately in the `iam` module for this reason) cost nothing to leave running and persist between sessions, so nothing has to be rebuilt from scratch each time. The AWS account has a $50/month budget alert plus a zero-spend safety net configured. In steady active development, this setup runs for pennies; once the platform is feature-complete and torn down, it costs $0/month.

## Screenshots

Reproducibility evidence — `terraform apply`/`destroy` output, AWS Console views, `kubectl`/ArgoCD/Grafana output — organized by component. Each group shows that piece verified against the live cluster/account, not just Terraform's own report of what it did.

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
![Grafana Explore showing live Loki logs from the api pods](screenshots/grafana-loki-explore.png)
