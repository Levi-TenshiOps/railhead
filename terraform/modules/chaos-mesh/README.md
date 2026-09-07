# chaos-mesh

Installs [Chaos Mesh](https://chaos-mesh.org/) (chart version pinned via `chaos_mesh_chart_version`, currently `2.8.4`) into its own `chaos-mesh` namespace, so real faults can be injected into the running cluster and the platform's own detection and remediation measured against them. Nothing here is an experiment: the experiment manifests live in `chaos/` and are applied by hand, never deployed state.

**Why this module exists at all rather than a sixth ArgoCD Application.** Two reasons, and the second is the load-bearing one.

Architecturally, Chaos Mesh is platform tooling in the same category as ArgoCD itself — it operates *on* the cluster rather than running in it, and letting the GitOps controller manage a tool built to disrupt GitOps-managed resources is a circularity worth avoiding.

Mechanically, it does not work under ArgoCD. With `webhook.certManager.enabled: false` (the chart default, and what this module uses) the chart generates the admission webhook's CA, certificate and key itself, at **Helm render time**, via `genCA`/`genSignedCert` — not at runtime in the controller. That generation is non-deterministic, so a controller that re-renders on every sync produces a fresh certificate each time, sees permanent drift, and `selfHeal` writes a `caBundle` that no longer matches the key the webhook server is actually serving. Creating any chaos CR then fails with `x509: certificate signed by unknown authority` (upstream [chaos-mesh#4764](https://github.com/chaos-mesh/chaos-mesh/issues/4764), open). Terraform renders once and keeps the result in state, so nothing re-renders to disagree with it. Full detail: `docs/known-gotchas.md` #29.

**Values that are not cosmetic.**
- `chaosDaemon.runtime: containerd` and `socketPath: /run/containerd/containerd.sock` — the chart defaults to Docker, which is wrong for EKS 1.34 (containerd 2.2.5). Getting this pair wrong is not a crash: `chaos-daemon` starts, reports `Ready`, and silently injects nothing.
- `controllerManager.replicaCount: 1`, down from the chart's 3 — on a two-node cluster a third replica cannot land on a distinct node, so it buys no availability.
- `dashboard.securityMode: false` — disables the dashboard's credential prompt so it uses its ServiceAccount. Acceptable only because the dashboard is ClusterIP with no ingress and is reached by `kubectl port-forward` alone. **If it is ever given an ingress, this must flip back to `true` first.**

**Known gotchas.**
- **Any future `helm upgrade` of this release regenerates the webhook certificates.** A chart version bump is a webhook-affecting change: verify it by creating a chaos CR afterwards. Pods going `Ready` proves nothing here.
- **Helm does not remove CRDs on uninstall.** 23 `chaos-mesh.org` CRDs and three cluster-scoped webhook configurations survive a destroy of this release. They are scoped to `apiGroups: ["chaos-mesh.org"]` so they cannot block anything else, but a chaos CR left alive past teardown step 4 becomes undeletable — its finalizer has no controller and its webhook fails closed. `docs/teardown-sequence.md` step 4 treats clearing chaos CRs as a prerequisite for exactly this reason.
- **`chaos-daemon` logs a `/dev/fuse` `ERROR` on every node and mostly does not mean it.** The nodes run cgroup v2, which has no `devices` controller, so the grant cannot succeed. Non-fatal — PodChaos, NetworkChaos, StressChaos, TimeChaos, DNSChaos and HTTPChaos all work. IOChaos, which depends on FUSE, does not; a planned storage-latency scenario was dropped on that constraint. `docs/known-gotchas.md` #30.

**Inputs:** `cluster_name` (required — it exists mainly to give this module an explicit dependency edge on `module.eks`, so a targeted destroy of the cluster sweeps Chaos Mesh up with it; the chart itself needs no cluster name, so the value is spent on a namespace label), `chaos_mesh_chart_version` (default `2.8.4`).

**Outputs:** `namespace`, `chart_version`.
