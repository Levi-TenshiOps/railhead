# Rebuild sequence

Brings the cluster back after a teardown: **three targeted Terraform passes plus
a manual CRD bootstrap.** A bare `terraform apply` from a destroyed state cannot
complete — the ArgoCD `Application` resources can't be planned until ArgoCD's own
CRDs exist, and the same apply is what installs them (`known-gotchas.md` #12).

**Step order is load-bearing — do not reorder or skip.** No command carries
`-auto-approve`, so each Terraform pass prompts; add it for non-interactive runs.
Every pass is resumable — re-run the identical command and it continues.

Confirm DNS resolves before starting; step 1 is a 12-minute apply.
```
Resolve-DnsName eks.us-east-1.amazonaws.com -ErrorAction Stop | Out-Null; "DNS OK"
```
If that fails — or a pass dies mid-run with `no such host` — run `ping 8.8.8.8`.
Failing means the uplink dropped: wait two minutes and retry, and change nothing
locally. Succeeding means the fault is local. Either way read `known-gotchas.md`
#17 before touching a network setting; both faults look identical and need
opposite responses.

## 1. Foundation and cluster — ~12 min
```
terraform -chdir=terraform/environments/dev apply "-target=module.vpc" "-target=module.iam" "-target=module.ecr" "-target=module.eks"
```
**Expect `33 added`.** Quote the `-target` arguments — unquoted, PowerShell splits
them and Terraform rejects the command. The EKS control plane accounts for 8–10
minutes of that, the node group another 3.

## 2. ArgoCD alone, to install its CRDs — ~2 min
```
terraform -chdir=terraform/environments/dev apply "-target=module.argocd.helm_release.argocd"
kubectl get crd | Select-String argoproj
```
**Expect `2 added`** — the `argocd` namespace and the Helm release. That is
complete, not a partial failure; `railhead-repo-credentials` is not a dependency
of `helm_release.argocd`, so `-target` skips it until step 3.

**Expect three `argoproj.io` CRDs.** Without them step 3 fails with `API did not
recognize GroupVersionKind from manifest (CRD may not be installed)`.

## 3. Everything else — under 1 min
```
terraform -chdir=terraform/environments/dev apply
```
**Expect `16 added`** — the five `Application` resources, the `railhead` and
`monitoring` namespaces, `railhead-repo-credentials`, the dashboards, and the
Slack and Postgres Secrets.

**Go straight to step 4 — do not pause here.** ArgoCD starts syncing
`observability` the moment this pass creates it and gives up after five failed
attempts. Bootstrap the CRDs before it exhausts them and it self-heals; let it run
out and you need step 5 (`known-gotchas.md` #14).

## 4. MANUAL — bootstrap the Prometheus Operator CRDs — under 1 min
Nothing in Terraform or ArgoCD does this, and a cluster destroy removes them.
```
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update prometheus-community
helm pull prometheus-community/kube-prometheus-stack --version 87.17.0 --untar --untardir C:\temp\crds
kubectl apply --server-side --force-conflicts -f C:\temp\crds\kube-prometheus-stack\charts\crds\crds\
kubectl get crd | Select-String monitoring.coreos.com
```
**Expect ten CRDs.** Pin the same version as `kube_prometheus_stack_chart_version`
in `terraform/modules/argocd/variables.tf` — currently **87.17.0**; the CRDs must
match the chart ArgoCD is deploying. Why this is manual, and why the chart is told
`crds.enabled = false`: `known-gotchas.md` #14.

## 5. Recovery — only if `observability` is still stuck
Skip this if step 4 followed step 3 promptly; on a clean run it is not needed. Use
it only when the Application sits at `OutOfSync / Missing` with the CRDs already
present — ArgoCD has exhausted its retries and a refresh will not restart it.
```
'{"operation":{"initiatedBy":{"username":"manual"},"sync":{"syncOptions":["ServerSideApply=true"],"prune":true}}}' | Set-Content sync.json -Encoding ascii
kubectl -n argocd patch application observability --type merge --patch-file sync.json
```
Use `--patch-file`, not inline JSON — PowerShell mangles it and kubectl rejects it
with `error decoding patch` (#20). Write the file `-Encoding ascii`; `utf8` adds a
BOM (#16). Reaches `Synced / Healthy` about two minutes later.

## Verification
```
kubectl get nodes
kubectl -n argocd get applications
kubectl get pods -A | Select-String -Pattern "Pending|Error|CrashLoop"
kubectl get pvc -A
```
- **Nodes** — 2x `t3.large` `Ready`, one in `us-east-1a`, one in `us-east-1b`.
- **Applications** — all five (`alloy`, `loki`, `observability`, `railhead`,
  `railhead-remediator`) `Synced`/`Healthy`. `observability` is slowest; give it a
  few minutes before treating it as stuck.
- **Problem pods** — no output. Two `railhead-api` pods showing **2–3 restarts
  each** is expected: they race Postgres on first start and settle on retry.
- **PVCs** — three `Bound`: `observability-grafana` (2Gi), `storage-loki-0` (5Gi),
  `data-railhead-postgresql-0` (2Gi).

**All-green in about 20 minutes** — ~12 for step 1, ~2 for step 2, under a minute
each for steps 3 and 4, then ~5 for the Applications to converge.
</content>
