# chaos/

Chaos Mesh experiment manifests for the Week 7 scenarios.

**Nothing here is deployed state.** These are applied by hand and deleted
afterwards. No ArgoCD Application points here, and none should — which is also
why this sits beside `terraform/` and `kubernetes/` rather than inside them:
`kubernetes/helm-charts/` is what ArgoCD syncs, and putting hand-applied
manifests there would blur a line the GitOps story depends on.

| Path | What it is |
|---|---|
| `experiments/01-networkchaos-api-postgres-partition.yaml` | Scenario 1. Contains a `__POD_NAME__` placeholder — do not apply directly |
| `experiments/02-podchaos-postgres-failure.yaml` | Scenario 2. Applies as-is |
| `run-scenario-1.ps1` | Resolves the live api pod name, renders scenario 1, applies only with `-Apply` |
| `tests/metric-on-client-abandon.py` | Pre-flight assumption test for scenario 1 |

Commands and timings: [`../docs/week7-chaos-runbook.md`](../docs/week7-chaos-runbook.md).
Results: [`../docs/week7-chaos-scorecard.md`](../docs/week7-chaos-scorecard.md).
Why Chaos Mesh runs via Terraform rather than ArgoCD:
[`../docs/known-gotchas.md`](../docs/known-gotchas.md) #29.

**Delete every chaos CR before teardown.** Once the `chaos-mesh` namespace is
gone the controller cannot clear a CR's finalizer and its webhook fails closed,
so a surviving chaos CR becomes undeletable
([`teardown-sequence.md`](../docs/teardown-sequence.md) step 4).
