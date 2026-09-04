# chaos/

Chaos Mesh experiment manifests for the Week 7 scenarios.

**Nothing here is deployed state.** These are applied by hand during an
experiment session and deleted afterwards. No ArgoCD Application points at this
directory, and none should: Chaos Mesh itself is deployed by Terraform rather
than by ArgoCD for a specific reason (`docs/known-gotchas.md` #29), and the
experiments it runs are ad-hoc by nature.

That is also why this sits beside `terraform/` and `kubernetes/` rather than
inside them. `kubernetes/helm-charts/` is what ArgoCD syncs; putting
hand-applied manifests there would blur a line the whole GitOps story depends
on.

| Path | What it is |
|---|---|
| `experiments/01-networkchaos-api-postgres-partition.yaml` | Scenario 1. Contains a `__POD_NAME__` placeholder — do not apply directly |
| `experiments/02-podchaos-postgres-failure.yaml` | Scenario 2. Applies as-is |
| `run-scenario-1.ps1` | Resolves the live api pod name, renders scenario 1, applies only with `-Apply` |
| `tests/metric-on-client-abandon.py` | Pre-flight assumption test for scenario 1. Run before injecting anything |

Execution order, expected timings and cleanup are in
`docs/week7-chaos-runbook.md`. Predictions and results are in
`docs/week7-chaos-scorecard.md`.

**Delete every chaos CR before teardown.** Once the `chaos-mesh` namespace is
gone the controller cannot clear a CR's finalizer and its webhook fails closed,
so a surviving chaos CR becomes undeletable (`docs/teardown-sequence.md`
step 4).
