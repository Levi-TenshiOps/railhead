# eks

Creates a managed Kubernetes cluster: an EKS control plane plus a managed node group, with IRSA roles for the core add-ons and for Loki, and the add-ons themselves installed directly through Terraform.

**Control plane.** A dedicated IAM role (`AmazonEKSClusterPolicy`) lets EKS manage the control plane on this account's behalf. Only `api` and `audit` cluster log types are enabled — not `authenticator`, `controllerManager`, or `scheduler`, which are chatty internal control-loop logs that mostly matter for debugging those components specifically; enabling all five would mostly add CloudWatch Logs cost and noise without adding much value here. The endpoint is public-only (`endpoint_private_access = false`).

**This cluster's own OIDC provider.** Every EKS cluster runs its own OIDC issuer that can vouch for the identity of Kubernetes ServiceAccounts running inside it — this is what IRSA (IAM Roles for Service Accounts) is built on. This is a *second, unrelated* OIDC provider from the one the `iam` module registers for GitHub Actions: same underlying AWS mechanism (an IAM OIDC identity provider + `AssumeRoleWithWebIdentity`), two separate identity sources for two separate purposes — one authenticates CI jobs, this one authenticates in-cluster Pods. Easy to conflate; worth keeping straight.

**Node group.** A node-level IAM role carries `AmazonEKSWorkerNodePolicy`, `AmazonEC2ContainerRegistryReadOnly`, and `AmazonEKS_CNI_Policy`. The managed node group itself is 2x `t3.large` on-demand instances (AL2023), scaling 2-4. The size is set by the VPC CNI's pod-per-node ceiling rather than by CPU or memory — `t3.medium` caps out at 17 pods, `t3.large` at 35.

**IRSA roles.** Three pod-scoped roles, all trusting this cluster's own OIDC provider:
- **VPC CNI** (`kube-system:aws-node`) — uses the AWS-managed `AmazonEKS_CNI_Policy`. The node role above *also* carries this same policy at the node level; that's intentional, not redundant — the CNI needs the node-level baseline to bootstrap at all, before the pod-scoped IRSA role (the more precise, least-privilege path) takes over for actual addon operation.
- **EBS CSI driver** (`kube-system:ebs-csi-controller-sa`) — uses the AWS-managed `AmazonEBSCSIDriverPolicy`.
- **Loki** (`monitoring:loki`) — a custom least-privilege policy (Get/Put/Delete/List) scoped to exactly one S3 bucket, since no AWS-managed policy fits "read/write objects in exactly this bucket." The bucket itself is created in the `iam` module, not here (see that module's README) — this role's `loki_bucket_arn` input comes from that module's output.

**Managed add-ons.** `vpc-cni`, `coredns`, `kube-proxy`, and `aws-ebs-csi-driver`, all applied directly through Terraform (`aws_eks_addon`) rather than left to EKS's own defaults, and all depending on the node group so they aren't left waiting/unhealthy before any compute exists to schedule them onto.

**Known gotcha — IRSA role placement split.** The Loki S3 bucket lives in the `iam` module so it survives independently of EKS teardown, the same way ECR does. But the IRSA *role* that grants access to that bucket lives here, in `eks`, instead — because its trust policy depends on this cluster's own OIDC provider, which gets destroyed and recreated every time the cluster does. Putting both bucket and role in the same module would have coupled the `iam` module's apply/destroy to EKS's lifecycle, breaking the "iam/ecr survive independent of EKS teardown" pattern this project relies on for fast rebuilds.

**Inputs:** `cluster_name` (default `railhead-dev`), `kubernetes_version` (default `1.34`), `subnet_ids` (required, the private subnets from the `vpc` module), `loki_bucket_arn` (required, from the `iam` module).

**Outputs:** `cluster_name`, `cluster_endpoint`, `cluster_certificate_authority_data`, `oidc_provider_arn`, `loki_irsa_role_arn`.

**Cost note:** the control plane (a flat hourly rate) and the 2x `t3.large` node group are the billable pieces of this module — both are destroyed at the end of each working session (see the root README's Cost approach section).
