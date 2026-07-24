# Teardown sequence (for next session)

Recorded 2026-07-24, not run — cluster stays up overnight.

1. **Delete ArgoCD Applications** (stops selfHeal fighting cleanup):
   ```
   kubectl delete application railhead railhead-remediator observability loki alloy -n argocd
   ```
   If a workload doesn't cascade-delete, delete its namespace directly instead.

2. **Verify PVCs and EBS volumes are gone:**
   ```
   kubectl get pvc -A
   aws ec2 describe-volumes --filters "Name=tag:kubernetes.io/created-for/pvc/name,Values=*" --region us-east-1
   ```
   Expect three PVCs gone: `observability-grafana`, `storage-loki-0`, `data-railhead-postgresql-0`.

3. **Destroy EKS + VPC together, one command:**
   ```
   terraform destroy -target=module.eks -target=module.vpc
   ```
   Not sequentially — public-only EKS endpoint means node traffic routes via the NAT
   Gateway; destroying it before the nodes hangs cleanup. Verify after via `aws eks
   describe-cluster` / `aws ec2 describe-vpcs`, not just Terraform's own report.
