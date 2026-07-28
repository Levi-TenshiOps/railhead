# Teardown sequence

Removes every billable resource at the end of a session. The S3 state bucket,
DynamoDB lock table, ECR repositories, and the GitHub OIDC IAM role are
deliberately kept — they cost pennies and rebuilding them wastes CI time.

**Step order is load-bearing — do not reorder or skip.** The destroy in step 5
does not carry `-auto-approve`, so it prompts; add it for non-interactive runs.

Confirm DNS resolves before starting; step 5 is a ~11-minute destroy.
```
Resolve-DnsName iam.amazonaws.com -ErrorAction Stop | Out-Null; "DNS OK"
```
If that fails — or a command dies mid-run with `no such host` — run `ping
8.8.8.8`. Failing means the uplink dropped: wait two minutes and retry, and
change nothing locally. Succeeding means the fault is local. Either way read
`known-gotchas.md` #17 before touching a network setting; both faults look
identical and need opposite responses.

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

## 4. Delete the argocd namespace, before Terraform runs
```
kubectl delete namespace argocd
```
**Expect** completion in under 20 seconds. Terraform owns this namespace and
would destroy it in step 5 — but there the deletion races the node group going
away. Once the NAT Gateway is gone the nodes go `NotReady`, kubelet can never
confirm pod shutdown, and finalization blocks on pods that will never report
(`known-gotchas.md` #19). Deleting it here, while the cluster is healthy, avoids
the hang entirely.

## 5. Destroy EKS and the VPC together, in one command
```
terraform -chdir=terraform/environments/dev destroy "-target=module.eks" "-target=module.vpc"
```
**Expect `51 destroyed`, around 11 minutes.** Not sequentially — the cluster's API
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
```
**Expect all nine empty.** Unassociated Elastic IPs are the easiest to miss — free
while attached to a NAT Gateway, billed hourly the moment the NAT goes away. The
VPC and security-group checks are last for a reason: neither costs anything on its
own, but both survive a partially-failed destroy, and a leftover VPC will collide
with the next rebuild.

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
</content>
