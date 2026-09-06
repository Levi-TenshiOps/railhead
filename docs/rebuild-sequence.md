# Rebuild sequence

Brings the cluster back after a teardown: **three targeted Terraform passes plus
a manual CRD bootstrap.** A bare `terraform apply` from a destroyed state cannot
complete — the ArgoCD `Application` resources can't be planned until ArgoCD's own
CRDs exist, and the same apply is what installs them (`known-gotchas.md` #12).

**Step order is load-bearing — do not reorder or skip.** No command carries
`-auto-approve`, so each Terraform pass prompts; add it for non-interactive runs.
Every pass is resumable — re-run the identical command and it continues.

Confirm DNS resolves before starting; step 1 is a 12-minute apply.
```powershell
Resolve-DnsName eks.us-east-1.amazonaws.com -ErrorAction Stop | Out-Null; "DNS OK"
```
If that fails — or a pass dies mid-run with `no such host` — run `ping 8.8.8.8`.
Failing means the uplink dropped: wait two minutes and retry, and change nothing
locally. If it succeeds, ask a third question before blaming DNS: **does the
failing hostname still exist?** A destroyed cluster's endpoint is gone, and that
resolves-to-nothing exactly like a network fault (#21, #22). Only once the name
is known to be valid is this a real DNS problem — see `known-gotchas.md` #17
before touching a network setting.

## 1. Foundation and cluster — ~12 min
```powershell
terraform -chdir=terraform/environments/dev apply "-target=module.vpc" "-target=module.iam" "-target=module.ecr" "-target=module.eks"
```
**Expect `0 to change, 0 to destroy` and roughly 40 added.** The exact count
moves with every infrastructure change and is not worth chasing — it has been
wrong twice already, and both times it flagged a stale document, not a broken
cluster. The *shape* is what must never move: a change or a destroy in this pass
means state disagrees with reality, and that is the signal to stop. The
**Verification** section at the end covers what this misses — a resource that
was never created at all.

Quote the `-target` arguments — unquoted, PowerShell splits them and Terraform
rejects the command with `Invalid target "module"`. The EKS control plane
accounts for 8–10 minutes of that, the node group another 3.

## 1b. Point kubectl at the new cluster — required before any kubectl command
```powershell
aws eks update-kubeconfig --name railhead-dev --region us-east-1
kubectl get nodes
```
**Expect** `Updated context arn:aws:eks:...:cluster/railhead-dev`, then `kubectl
get nodes` to answer with two `t3.large` nodes. They may still be joining — what
matters here is that the command responds at all, not that they are `Ready` yet.

A rebuild gives the cluster a brand-new API endpoint, but kubeconfig still holds
the *destroyed* cluster's. Until this runs, every kubectl command in this
document and in `teardown-sequence.md` fails with `no such host` against a
hostname that no longer exists — which looks exactly like a network fault and is
not (`known-gotchas.md` #21).

## 2. ArgoCD alone, to install its CRDs — ~2 min

**Refresh the helm repo indexes first.** The `helm` provider resolves the chart
from a cached index, not from the repo list, and the cache lives in
`%TEMP%\helm\repository` where Windows cleanup deletes it. `helm repo list` keeps
reporting all four repos regardless, so this fails as
`Unable to locate chart argo-cd: no cached repo found` while everything looks
configured. It is time-dependent — fine on a rebuild soon after the last one,
broken once cleanup has run (`known-gotchas.md` #24).
```powershell
helm repo add chaos-mesh https://charts.chaos-mesh.org --force-update
helm repo update
terraform -chdir=terraform/environments/dev apply "-target=module.argocd.helm_release.argocd"
kubectl get crd | Select-String argoproj
```
`helm repo update` only refreshes repos already *registered*, so `chaos-mesh`
must be added first or step 3 cannot resolve the chart. `--force-update` keeps
the line re-runnable; plain `helm repo add` exits non-zero once the repo exists
(`known-gotchas.md` #23).
**Expect `2 added`** — the `argocd` namespace and the Helm release. That is
complete, not a partial failure; `railhead-repo-credentials` is not a dependency
of `helm_release.argocd`, so `-target` skips it until step 3.

**Expect three `argoproj.io` CRDs.** Without them step 3 fails with `API did not
recognize GroupVersionKind from manifest (CRD may not be installed)`.

## 3. Everything else — under 1 min
```powershell
terraform -chdir=terraform/environments/dev apply
```
**Expect `0 to change, 0 to destroy`, and roughly 18 added** — the five
`Application` resources, the `railhead` and `monitoring` namespaces,
`railhead-repo-credentials`, the dashboards, the Slack and Postgres Secrets, and
the `chaos-mesh` namespace and Helm release.

**Chaos Mesh is created here, not in a pass of its own** — `module.chaos_mesh`
consumes `module.eks` outputs, so this untargeted apply satisfies it. It is
Terraform-deployed rather than a sixth ArgoCD Application because under ArgoCD
its admission webhook breaks (`known-gotchas.md` #29). Do not convert it.

**Go straight to step 4 — do not pause here.** ArgoCD starts syncing
`observability` the moment this pass creates it and gives up after five failed
attempts. Bootstrap the CRDs before it exhausts them and it self-heals; let it run
out and you need step 5 (`known-gotchas.md` #14).

## 4. MANUAL — bootstrap the Prometheus Operator CRDs — under 1 min
Nothing in Terraform or ArgoCD does this, and a cluster destroy removes them.
```powershell
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update prometheus-community
Remove-Item C:\temp\crds\kube-prometheus-stack -Recurse -Force -ErrorAction SilentlyContinue
helm pull prometheus-community/kube-prometheus-stack --version 87.17.0 --untar --untardir C:\temp\crds
Select-String -Path C:\temp\crds\kube-prometheus-stack\Chart.yaml -Pattern "^version:"
kubectl apply --server-side --force-conflicts -f C:\temp\crds\kube-prometheus-stack\charts\crds\crds
kubectl get crd | Select-String monitoring.coreos.com
```

`C:\temp\crds` is arbitrary — any writable path works, but it must match in
all four lines. Pass the **directory**, not a `crd-*.yaml` glob. PowerShell does not expand globs
for native commands, so kubectl receives the literal `crd-*.yaml` and fails with
`The filename, directory name, or volume label syntax is incorrect` — the glob
form has never worked as written on this shell (`known-gotchas.md` #20). Every
file in that directory is a CRD, so the directory form is equivalent.
**The printed version MUST match the pin before you apply.** If it does not, stop:
the extract is stale and the CRDs would not match the chart ArgoCD deploys.

The `Remove-Item` is not tidiness — `helm pull --untar` fails outright if the
target directory already exists, so on any rebuild after the first it exits 1
while the following `kubectl apply` runs anyway against the *previous* extract
and reports success. Deleting first makes the step repeatable; printing the
version makes the mismatch visible if it ever isn't (`known-gotchas.md` #23).

**Expect ten CRDs.** Pin the same version as `kube_prometheus_stack_chart_version`
in `terraform/modules/argocd/variables.tf` — currently **87.17.0**; the CRDs must
match the chart ArgoCD is deploying. Why this is manual, and why the chart is told
`crds.enabled = false`: `known-gotchas.md` #14.

## 5. Recovery — only if `observability` is still stuck
Skip this if step 4 followed step 3 promptly; on a clean run it is not needed. Use
it only when the Application sits at `OutOfSync / Missing` with the CRDs already
present — ArgoCD has exhausted its retries and a refresh will not restart it.
```powershell
'{"operation":{"initiatedBy":{"username":"manual"},"sync":{"syncOptions":["ServerSideApply=true"],"prune":true}}}' | Set-Content sync.json -Encoding ascii
kubectl -n argocd patch application observability --type merge --patch-file sync.json
```
Use `--patch-file`, not inline JSON — PowerShell mangles it and kubectl rejects it
with `error decoding patch` (#20). Write the file `-Encoding ascii`; `utf8` adds a
BOM (#16). Reaches `Synced / Healthy` about two minutes later.

## Verification
```powershell
kubectl get nodes
kubectl -n argocd get applications
kubectl get pods -A | Select-String -Pattern "Pending|Error|CrashLoop"
kubectl get pvc -A
kubectl -n chaos-mesh get pods
kubectl -n amazon-cloudwatch get pods
aws cloudwatch describe-alarms --region us-east-1 --query "MetricAlarms[].[AlarmName,StateValue]" --output table
```
- **Nodes** — 2x `t3.large` `Ready`, one in `us-east-1a`, one in `us-east-1b`.
- **Applications** — all five (`alloy`, `loki`, `observability`, `railhead`,
  `railhead-remediator`) `Synced`/`Healthy`. `observability` is slowest; give it a
  few minutes before treating it as stuck.
- **Problem pods** — no output. Two `railhead-api` pods showing **2–3 restarts
  each** is expected: they race Postgres on first start and settle on retry.
  *Observation to watch:* the 2026-08-30 rebuild produced **zero** restarts. One
  observation is not enough to change this line, but if it holds on the next
  rebuild the race is less deterministic than documented, or something changed.
- **PVCs** — three `Bound`: `observability-grafana` (2Gi), `storage-loki-0` (5Gi),
  `data-railhead-postgresql-0` (2Gi). Chaos Mesh adds none — the dashboard runs
  on an `emptyDir` by design.
- **Chaos Mesh** — five pods `Running`: `chaos-controller-manager`,
  `chaos-dashboard`, `chaos-dns-server`, and `chaos-daemon` on **both** nodes.
  A `/dev/fuse` `ERROR` in the daemon logs is expected and non-fatal
  (`known-gotchas.md` #30).
- **amazon-cloudwatch** — three pods `Running`: the controller-manager and a
  `cloudwatch-agent` per node.
- **Alarms** — all three `OK`: `railhead-dev-apiserver-storage-growth`,
  `railhead-dev-node-filesystem-high`, `railhead-dev-remediator-down`. They pass
  through `INSUFFICIENT_DATA` first; that is not a failure.

**All-green in about 20 minutes** — ~12 for step 1, ~2 for step 2, under a minute
each for steps 3 and 4, then ~5 for the Applications to converge.
