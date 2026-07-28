# Teardown sequence

Run this at the end of a session to remove every billable resource. The S3 state
bucket, DynamoDB lock table, ECR repositories, and the GitHub OIDC IAM role are
deliberately kept — they cost pennies and rebuilding them wastes CI time.

Order matters more than it looks like it should. Steps 2 and 4 exist because of
failures actually hit during a real teardown, not out of caution.

**Before starting, pre-resolve the AWS endpoints.** On a workstation where DNS
resolves intermittently, the destroy in step 5 is just as exposed as a rebuild —
one run hit `iam.amazonaws.com: no such host` three times and left four IAM
resources behind, and another failed to write state back to S3 afterwards.
Resolving the endpoints first makes this much less frequent:

```
$hosts = @("iam.amazonaws.com","sts.us-east-1.amazonaws.com","ec2.us-east-1.amazonaws.com",
           "eks.us-east-1.amazonaws.com","s3.us-east-1.amazonaws.com","dynamodb.us-east-1.amazonaws.com",
           "api.ecr.us-east-1.amazonaws.com","railhead-tfstate-993268717190.s3.us-east-1.amazonaws.com")
foreach ($h in $hosts) { 1..5 | ForEach-Object { Resolve-DnsName $h -ErrorAction SilentlyContinue | Out-Null } }
```

See the multi-adapter DNS entry in `known-gotchas.md` for why this happens.

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

   **A partial failure is expected and recoverable.** Terraform destroy is
   resumable — if it exits non-zero having destroyed most resources (commonly a
   DNS failure on an IAM `DetachRolePolicy` call), re-run the identical command
   and it continues from where it stopped. Verify with `terraform state list`
   rather than assuming the teardown failed. One real run exited 1 having
   destroyed 47 of 50 resources; everything billable was already gone and only
   four free IAM objects remained.

   If instead it fails at the very end with `Failed to persist state to backend`,
   the resources *were* destroyed but the result never reached S3. Terraform
   writes the correct state to `errored.tfstate` in the working directory and
   tells you to run `terraform state push errored.tfstate`. Check that its
   `lineage` matches the remote state and its `serial` is exactly one higher
   before pushing.

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
   aws ec2 describe-vpcs --region us-east-1 --query "Vpcs[?!IsDefault].[VpcId,Tags[?Key=='Name'].Value|[0]]" --output table
   aws ec2 describe-security-groups --region us-east-1 --query "SecurityGroups[?GroupName!='default'].[GroupId,GroupName]" --output table
   ```
   All nine should come back empty. Unassociated Elastic IPs are the easiest
   one to miss — they cost nothing while attached to a NAT Gateway and start
   billing hourly the moment the NAT goes away. The VPC and security-group
   checks are the last two: neither costs anything on its own, but both survive
   a partially-failed destroy and a leftover VPC will collide with the next
   rebuild.

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
