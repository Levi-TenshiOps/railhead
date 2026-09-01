# Teardown sequence

Removes every billable resource at the end of a session. The S3 state bucket,
DynamoDB lock table, ECR repositories, and the GitHub OIDC IAM role are
deliberately kept — they cost pennies and rebuilding them wastes CI time.

**Step order is load-bearing — do not reorder or skip.** The destroy in step 5
does not carry `-auto-approve`, so it prompts; add it for non-interactive runs.

**First, confirm kubectl is pointed at the cluster you actually mean to destroy.**
```
kubectl config current-context
```
It must name `railhead-dev`. This is a **safety check, not a connectivity
check** — the danger is not that kubectl fails, it is that it succeeds against
the wrong cluster. A stale kubeconfig still pointing at some other *live*
cluster would let steps 1–4 delete namespaces there, and every command would
report success.

Know its limit: the context *name* is identical for every rebuild of this
cluster, so this check catches pointing at the wrong cluster but cannot detect a
stale kubeconfig aimed at a dead endpoint — it reads as correct either way. Step
1b of `rebuild-sequence.md` is what covers that case.

Confirm DNS resolves before starting; step 5 is a ~11-minute destroy.
```
Resolve-DnsName iam.amazonaws.com -ErrorAction Stop | Out-Null; "DNS OK"
```
If that fails — or a command dies mid-run with `no such host` — run `ping
8.8.8.8`. Failing means the uplink dropped: wait two minutes and retry, and
change nothing locally. If it succeeds, ask a third question before blaming DNS:
**does the failing hostname still exist?** A destroyed cluster's endpoint is
gone, and that resolves-to-nothing exactly like a network fault (#21, #22). Only
once the name is known to be valid is this a real DNS problem — see
`known-gotchas.md` #17 before touching a network setting.

## 1. Delete the five ArgoCD Application CRs
So selfHeal stops recreating what the next steps remove.
```
kubectl -n argocd delete application railhead railhead-remediator observability loki alloy
```

## 2. Delete the namespaces those Applications deployed into
This is the step that actually removes the workloads and their PVCs.
```
kubectl delete namespace railhead monitoring
```
Step 1 does **not** do this. These Applications carry no
`resources-finalizer.argocd.argoproj.io`, so deleting the CR returns success
while every pod and PVC it deployed keeps running — untracked. `railhead` and
`railhead-remediator` deploy into `railhead`; `observability`, `loki`, and
`alloy` deploy into `monitoring`.

Do it now, while the cluster is still healthy. The EBS CSI controller runs
*inside* the cluster and is what honours the PVs' `Delete` reclaim policy —
destroy the cluster with PVCs still bound and nothing ever issues `DeleteVolume`,
so the volumes orphan and bill indefinitely (`known-gotchas.md` #7).

**Leave `amazon-cloudwatch` alone.** It holds the CloudWatch agent DaemonSet, but
unlike these two it is created by a Terraform-managed EKS add-on rather than by an
ArgoCD Application, so step 5 removes it. Verified: the add-on destroys in about
14 seconds and does not reproduce the finalization hang that makes `argocd` need
step 4.

## 3. Verify the PVCs are gone and the volumes were released
```
kubectl get pvc -A
kubectl get pv
aws ec2 describe-volumes --region us-east-1 --filters "Name=status,Values=available"
```
**Expect** all three PVCs gone — `data-railhead-postgresql-0` (2Gi),
`observability-grafana` (2Gi), `storage-loki-0` (5Gi) — and **zero** volumes
`available`. Loki's SingleBinary keeps its own 5Gi PVC for the WAL and index
cache even though chunks live in S3; it is not exempt.

## 4. Delete the argocd and chaos-mesh namespaces, before Terraform runs

**Prerequisite, not a sanity check: no chaos experiments may be outstanding.**
Chaos CRs carry a finalizer that only the chaos-controller-manager removes, and
the webhooks that guard those CRs stay behind after the controller is gone (see
below). Once this step runs, a surviving chaos CR can no longer be deleted at
all — the finalizer has no controller to clear it and the webhook rejects the
delete. Clear them *first*.
```
kubectl get podchaos,networkchaos,stresschaos,iochaos,timechaos,dnschaos,httpchaos -A
```
**Expect no resources found.** If anything is listed, delete it and confirm it
is gone *before* continuing. This is free today with no experiments running, and
becomes the difference between a clean teardown and a stuck one the moment
Week 7 scenarios are live.
```
kubectl delete namespace argocd chaos-mesh
```
**Expect around 45 seconds** (measured 45.8s on 2026-08-31). It deletes two
namespaces now, one of them holding a DaemonSet, so it takes noticeably longer
than the sub-20-second figure from when this step covered `argocd` alone — that
is normal progress, not a hang. Terraform owns both namespaces and
would destroy them in step 5 — but there the deletion races the node group going
away. Once the NAT Gateway is gone the nodes go `NotReady`, kubelet can never
confirm pod shutdown, and finalization blocks on pods that will never report
(`known-gotchas.md` #19). Deleting them here, while the cluster is healthy,
avoids the hang entirely.

`chaos-mesh` was originally included by analogy with `argocd`, and is now
**verified by a real teardown (2026-08-31)**: both namespaces deleted cleanly
with no hang and no manual intervention.

**What survives the `helm_release` destroy.** Helm does not remove CRDs on
uninstall, so Chaos Mesh's 23 CRDs stay, and so do three cluster-scoped webhook
configurations — `chaos-mesh-mutation`, `chaos-mesh-validation` and
`chaos-mesh-validation-auth` — all with `failurePolicy: Fail` and a backing
service that no longer exists.

They cannot block this teardown. Every rule in all three is scoped to
`apiGroups: ["chaos-mesh.org"]`, including the one that reads
`resources: ["*"]`, so they intercept chaos CRs and nothing else — no pods, no
namespaces, no core resources. Step 5 then removes the whole cluster along with
them.

What they *do* mean is the reason step 4's CR check above is a prerequisite: a
chaos CR left alive past this point cannot be deleted, because its finalizer has
no controller and its webhook fails closed. It would matter beyond teardown only
if chaos-mesh were ever uninstalled on its own, which would leave both the CRDs
and these webhooks orphaned.

## 5. Destroy EKS and the VPC together, in one command
```
terraform -chdir=terraform/environments/dev destroy "-target=module.eks" "-target=module.vpc"
```
**Expect `0 changed`, everything destroyed, exit 0, in around 11 minutes.** No
resource count is asserted here, for the same reason as `rebuild-sequence.md`
step 1: an exact number rots on every infrastructure change. What matters is the
shape — a *changed* resource in a destroy plan, or a non-zero exit, means
something disagrees with state and is the signal to stop.

An earlier version of this note guessed that a documented **51** and an observed
**59** differed because steps 1–4 delete resources out of band and plan-time
refresh drops them. **Measured on 2026-08-31: that is false.** The plan showed
61 before steps 1–4 ran and the destroy reported 61 after them — the count did
not move. The old 51 simply predates the CloudWatch feature's 7 resources and
chaos-mesh's 2. Deleting namespaces by hand does not change what Terraform
destroys, because those resources are still in state and Terraform removes them
either way. Not sequentially — the cluster's API
endpoint is public-only, so node-to-control-plane traffic routes out through the
NAT Gateway and back in, a dependency Terraform's graph cannot see. Destroying the
VPC first drops the nodes mid-teardown and hangs anything waiting on the
Kubernetes API. Quote the `-target` arguments; unquoted, PowerShell splits them
and Terraform rejects the command with `Invalid target "module"`.

**A partial failure is expected and recoverable.** Destroy is resumable — if it
exits non-zero having destroyed most resources (commonly a DNS failure on an IAM
`DetachRolePolicy` call), re-run the identical command and it continues. Confirm
with `terraform -chdir=terraform/environments/dev state list` rather than assuming
the teardown failed.

Use `state list`, not `plan`, for that check. After a *successful* teardown
`terraform plan` exits 1 with five `Failed to construct REST client` errors — one
per `kubernetes_manifest` Application, which validates against a cluster that no
longer exists. Expected by design; it says nothing about the health of the state.

If it instead fails at the very end with `Failed to persist state to backend`, the
resources *were* destroyed but the result never reached S3. Terraform writes the
correct state to `errored.tfstate` **in `terraform/environments/dev`, not your
shell's directory** — `-chdir` relocates it (`known-gotchas.md` #18). Check that
`lineage` matches the remote state and `serial` is exactly one higher, then push
it by bare filename; a path relative to your shell fails.
```
(Get-Content terraform\environments\dev\errored.tfstate -Raw | ConvertFrom-Json) | Select-Object lineage, serial
terraform -chdir=terraform/environments/dev state push errored.tfstate
```

## 6. Sweep for orphans
Terraform reporting success is not proof that nothing billable survived —
Kubernetes-created resources in particular are invisible to it.
```
aws ec2 describe-volumes    --region us-east-1 --filters "Name=status,Values=available"
aws ec2 describe-addresses  --region us-east-1 --query "Addresses[?AssociationId==null]"
aws elbv2 describe-load-balancers --region us-east-1
aws elb describe-load-balancers   --region us-east-1
aws ec2 describe-nat-gateways --region us-east-1 --filter "Name=state,Values=available"
aws eks list-clusters --region us-east-1
aws ec2 describe-instances --region us-east-1 --filters "Name=instance-state-name,Values=running"
aws ec2 describe-vpcs --region us-east-1 --query "Vpcs[?!IsDefault].[VpcId,Tags[?Key=='Name'].Value|[0]]" --output table
aws ec2 describe-security-groups --region us-east-1 --query "SecurityGroups[?GroupName!='default'].[GroupId,GroupName]" --output table
aws logs describe-log-groups --region us-east-1 --query "logGroups[?contains(logGroupName,'railhead') || contains(logGroupName,'containerinsights') || contains(logGroupName,'application-signals')].[logGroupName,retentionInDays]" --output table
```
**Expect all ten empty.** Unassociated Elastic IPs are the easiest to miss — free
while attached to a NAT Gateway, billed hourly the moment the NAT goes away. The
VPC and security-group checks are last for a reason: neither costs anything on its
own, but both survive a partially-failed destroy, and a leftover VPC will collide
with the next rebuild.

Check ten is deliberately matched on *substrings* rather than the two prefixes we
happen to create today. The point is catching groups nothing anticipated —
Container Insights can emit under `application`, `host`, `dataplane`, or
`application-signals` depending on which add-on features are enabled, and a check
that only confirms the groups already known about would have found nothing wrong
for three straight cycles. It did: `/aws/eks/railhead-dev/cluster` accumulated
**1.51 GB** of never-expiring audit logs across every session since 2026-07-11,
invisible because no sweep step looked for log groups at all. Both groups are now
Terraform-managed with 1-day retention, so a survivor self-deletes within a day —
**report it as a finding anyway.** A survivor means destroy ordering broke, and the
retention is only the backstop.

## If a namespace hangs in Terminating
Expected if the NAT Gateway is already gone. A `NamespaceDeletionContentFailure`
condition naming `Resource=pods` confirms it; force-deleting the pods clears the
blocker and finalization completes in about thirty seconds.
```
(kubectl get namespace <ns> -o json | ConvertFrom-Json).status.conditions | Format-List type, message
kubectl delete pods --all -n <ns> --force --grace-period=0
```
Why this rather than clearing the namespace's own finalizer, and why `kubectl`
still reaches the cluster with every node `NotReady`: `known-gotchas.md` #19.
