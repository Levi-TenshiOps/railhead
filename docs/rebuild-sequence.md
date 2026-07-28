# Rebuild sequence

Run this at the start of a session to bring the cluster back after a teardown.
It is not the mirror image of `teardown-sequence.md` — teardown is one Terraform
command, rebuild is **three targeted Terraform passes plus one manual step**.

A bare `terraform apply` from a destroyed state cannot complete. The reason is
ordering, not configuration: `kubernetes_manifest` validates its
GroupVersionKind against the live cluster at *plan* time, so the five ArgoCD
`Application` resources cannot even be planned until ArgoCD's own CRDs exist —
and those CRDs are installed by a Helm release in the same apply. Terraform has
no way to sequence that within a single run.

Every step below is what an actual rebuild required, not an idealised version.

1. **Pass 1 — foundation and cluster:**
   ```
   terraform -chdir=terraform/environments/dev apply "-target=module.vpc" "-target=module.iam" "-target=module.ecr" "-target=module.eks"
   ```
   Quote the `-target` arguments in PowerShell; unquoted, PowerShell splits them
   and Terraform rejects the command. Expect roughly 12–15 minutes — the EKS
   control plane alone takes 8–10, the node group another 3.

2. **Pass 2 — ArgoCD only, to install its CRDs:**
   ```
   terraform -chdir=terraform/environments/dev apply "-target=module.argocd.helm_release.argocd"
   ```
   This creates the `argocd` namespace, its repo-credentials Secret, and the
   Helm release. Confirm the CRDs landed before continuing:
   ```
   kubectl get crd | Select-String argoproj
   ```
   Expect three `argoproj.io` CRDs. Without them, pass 3 fails with
   `API did not recognize GroupVersionKind from manifest (CRD may not be installed)`.

3. **Pass 3 — everything else:**
   ```
   terraform -chdir=terraform/environments/dev apply
   ```
   The five `Application` resources plan cleanly now. This also creates the
   `railhead` and `monitoring` namespaces, the dashboards, and the Slack and
   Postgres Secrets.

4. **Pass 4 — MANUAL: bootstrap the Prometheus Operator CRDs.** Nothing in
   Terraform or ArgoCD does this, and a cluster destroy removes them:
   ```
   helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
   helm repo update prometheus-community
   helm pull prometheus-community/kube-prometheus-stack --version 87.17.0 --untar --untardir <workdir>
   kubectl apply --server-side --force-conflicts -f <workdir>/kube-prometheus-stack/charts/crds/crds/
   ```
   Pin the same version as `kube_prometheus_stack_chart_version` in
   `modules/argocd/variables.tf` (currently **87.17.0**) — the CRDs must match
   the chart ArgoCD is deploying.

   Why this is manual: the observability Application sets `crds.enabled = false`.
   These CRDs are enormous — `crd-prometheuses.yaml` alone is about 830 KB
   against Kubernetes' 256 KiB total-annotation-size limit, so client-side apply
   fails outright, and setting `ServerSideApply=true` on the Application did not
   resolve it in practice. `kubectl apply --server-side` on the CRD manifests
   directly does work, so they are bootstrapped out-of-band and the chart is told
   not to fight over them afterwards.

   Verify all ten:
   ```
   kubectl get crd | Select-String monitoring.coreos.com
   ```

5. **Pass 5 — only if `observability` is still stuck.** ArgoCD gives up after
   five failed sync attempts, and a refresh alone will not restart it — the
   Application sits at `OutOfSync / Missing` indefinitely even once the CRDs
   exist. Patch an explicit sync operation onto it:
   ```
   kubectl -n argocd patch application observability --type merge --patch-file <file>
   ```
   where the file contains:
   ```json
   {"operation":{"initiatedBy":{"username":"manual"},"sync":{"syncOptions":["ServerSideApply=true"],"prune":true}}}
   ```
   Pass the JSON via `--patch-file`, not inline — PowerShell mangles inline JSON
   and kubectl rejects it with `error decoding patch`. It reaches
   `Synced / Healthy` about two minutes later.

## Verification

```
kubectl get nodes
kubectl -n argocd get applications
kubectl get pods -A | Select-String -Pattern "Pending|Error|CrashLoop"
kubectl get pvc -A
```

Expected:

- **Nodes** — 2x `t3.large`, both `Ready`, one in `us-east-1a` and one in
  `us-east-1b`.
- **Applications** — all five (`alloy`, `loki`, `observability`, `railhead`,
  `railhead-remediator`) `Synced` and `Healthy`. `observability` is the slowest;
  give it a few minutes before treating it as stuck.
- **Problem pods** — no output. The two `railhead-api` pods showing ~2 restarts
  is expected and fine: they race Postgres on first start and settle on retry.
- **PVCs** — three `Bound`: `observability-grafana` (2Gi), `storage-loki-0`
  (5Gi), `data-railhead-postgresql-0` (2Gi).

A full rebuild to all-green takes roughly 30 minutes.

## If DNS fails mid-apply

On a workstation where AWS endpoints resolve intermittently, a long apply will
eventually hit `no such host` and abort partway. Terraform is resumable — re-run
the same pass and it continues. Pre-resolving the endpoints first makes this
much less frequent; the list must include the cluster's own API hostname
(`aws eks describe-cluster --query cluster.endpoint`), which is cluster-specific
and therefore changes on every rebuild. See the multi-adapter DNS entry in
`known-gotchas.md`.
