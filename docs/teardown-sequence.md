# Teardown sequence

Run this at the end of a session to remove every billable resource. The S3 state
bucket, DynamoDB lock table, ECR repositories, and the GitHub OIDC IAM role are
deliberately kept — they cost pennies and rebuilding them wastes CI time.

Order matters more than it looks like it should. Steps 2 and 4 exist because of
failures actually hit during a real teardown, not out of caution.

1. **Delete the five ArgoCD Application CRs** so selfHeal stops recreating what
   the next steps remove:
   ```
   kubectl -n argocd delete application railhead railhead-remediator observability loki alloy
   ```

2. **Delete the namespaces those Applications deployed into.** This is the step
   that actually removes the workloads and their PVCs:
   ```
   kubectl delete namespace railhead monitoring
   ```
   Deleting the Application CR alone does **not** do this. These Applications
   carry no `resources-finalizer.argocd.argoproj.io`, so deleting one removes
   the CR and leaves every pod and PVC it deployed still running — untracked.
   `railhead` and `railhead-remediator` deploy into `railhead`; `observability`,
   `loki`, and `alloy` deploy into `monitoring`.

   Do this while the cluster is still healthy. The EBS CSI controller runs
   *inside* the cluster, and it is what honours the PVs' `Delete` reclaim
   policy. Destroy the cluster with PVCs still bound and nothing ever issues
   `DeleteVolume` — the volumes orphan and bill indefinitely.

3. **Verify the PVCs are gone and the EBS volumes were actually released:**
   ```
   kubectl get pvc -A
   kubectl get pv
   aws ec2 describe-volumes --region us-east-1 --filters "Name=status,Values=available"
   ```
   Three PVCs exist: `data-railhead-postgresql-0` (2Gi), `observability-grafana`
   (2Gi), and `storage-loki-0` (5Gi). Loki's SingleBinary deployment keeps its
   own 5Gi PVC for the WAL and index cache even though chunks live in S3 — it is
   not exempt. Expect all three gone and zero volumes in `available` state.

4. **Delete the argocd namespace, before Terraform runs:**
   ```
   kubectl delete namespace argocd
   ```
   Terraform owns this namespace and will try to destroy it in step 5, but doing
   it there means the deletion races the node group going away. Once the NAT
   Gateway is gone the nodes go `NotReady`, kubelet can never confirm pod
   shutdown, and namespace finalization blocks on pods that will never report.
   Removing it here, while the cluster is healthy, avoids the hang entirely.

5. **Destroy EKS and the VPC together, in one command:**
   ```
   terraform -chdir=terraform/environments/dev destroy "-target=module.eks" "-target=module.vpc"
   ```
   Not sequentially. The cluster's API endpoint is public-only, so
   node-to-control-plane traffic routes out through the NAT Gateway and back in
   — a dependency Terraform's graph cannot see. Destroying the VPC first drops
   the nodes mid-teardown and hangs anything waiting on the Kubernetes API.

   Quote the `-target` arguments in PowerShell. Unquoted, PowerShell splits them
   and Terraform rejects the command with `Invalid target "module"`.

6. **Sweep for orphans.** Terraform reporting success is not proof that nothing
   billable survived — Kubernetes-created resources in particular are invisible
   to it:
   ```
   aws ec2 describe-volumes    --region us-east-1 --filters "Name=status,Values=available"
   aws ec2 describe-addresses  --region us-east-1 --query "Addresses[?AssociationId==null]"
   aws elbv2 describe-load-balancers --region us-east-1
   aws elb describe-load-balancers   --region us-east-1
   aws ec2 describe-nat-gateways --region us-east-1 --filter "Name=state,Values=available"
   aws eks list-clusters --region us-east-1
   aws ec2 describe-instances --region us-east-1 --filters "Name=instance-state-name,Values=running"
   ```
   All seven should come back empty. Unassociated Elastic IPs are the easiest
   one to miss — they cost nothing while attached to a NAT Gateway and start
   billing hourly the moment the NAT goes away.

## If a namespace hangs in Terminating

Expected, if the NAT Gateway is already gone. The nodes are `NotReady`, so
kubelet cannot confirm that pods have stopped, and the namespace waits forever
on pods that will never report. Check what is blocking it:

```
kubectl get namespace <ns> -o jsonpath='{range .status.conditions[*]}{.type}{": "}{.message}{"\n"}{end}'
```

`NamespaceDeletionContentFailure` naming `Resource=pods` confirms it. Force-delete
the pods to remove them from etcd directly, and finalization completes in about
thirty seconds:

```
kubectl delete pods --all -n <ns> --force --grace-period=0
```

Prefer this over clearing the namespace's own finalizer via a raw `PUT` to
`/api/v1/namespaces/<ns>/finalize` — force-deleting the pods removes the actual
blocker and lets the namespace finalize through its normal path.

`kubectl` keeps working against the cluster throughout, because your workstation
reaches the public API endpoint directly over the internet rather than through
the NAT Gateway the nodes depend on.
