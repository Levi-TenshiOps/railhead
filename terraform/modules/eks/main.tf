terraform {
  required_providers {
    aws = {
      source = "hashicorp/aws"
    }
    tls = {
      source = "hashicorp/tls"
    }
  }
}

# ---------------------------------------------------------------------------
# Control plane IAM role
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "cluster_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "cluster" {
  name               = "${var.cluster_name}-eks-cluster-role"
  assume_role_policy = data.aws_iam_policy_document.cluster_assume.json
}

resource "aws_iam_role_policy_attachment" "cluster_policy" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

# ---------------------------------------------------------------------------
# Control plane log group — MUST exist before the cluster.
#
# With enabled_cluster_log_types set, EKS creates this group itself during
# cluster creation if it doesn't already exist, and the group it creates
# never expires and is not owned by Terraform. That group then survives
# `terraform destroy` and orphans: found 1.51 GB of audit logs here dating
# back to the very first cluster, accumulated across every session since.
#
# Declaring it here and forcing the cluster to depend on it means Terraform
# creates it first, owns it, and destroys it with the cluster. The 1-day
# retention is the safety net if that ordering ever fails anyway.
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "cluster" {
  name              = "/aws/eks/${var.cluster_name}/cluster"
  retention_in_days = 1
}

# ---------------------------------------------------------------------------
# EKS control plane
# ---------------------------------------------------------------------------

# Only api/audit log types are enabled (not authenticator, controllerManager,
# scheduler). Those other three are extremely chatty internal control-loop
# logs that mostly matter if you're debugging the scheduler/controller-manager
# itself; api (every request to the API server) and audit (who did what) are
# the two that are actually valuable for the security/observability work this
# project cares about, so enabling all 5 would mostly just add CloudWatch
# Logs ingestion cost and noise without adding much for our purposes.
resource "aws_eks_cluster" "this" {
  name     = var.cluster_name
  role_arn = aws_iam_role.cluster.arn
  version  = var.kubernetes_version

  vpc_config {
    subnet_ids              = var.subnet_ids
    endpoint_public_access  = true
    endpoint_private_access = false
  }

  enabled_cluster_log_types = ["api", "audit"]

  depends_on = [
    aws_iam_role_policy_attachment.cluster_policy,
    aws_cloudwatch_log_group.cluster,
  ]
}

# ---------------------------------------------------------------------------
# This cluster's own OIDC provider (IRSA) — NOT the GitHub Actions one.
#
# The iam module built earlier registered GitHub's OIDC issuer
# (token.actions.githubusercontent.com) so GitHub Actions runs can assume an
# AWS role. This is a second, completely separate OIDC provider: every EKS
# cluster runs its own OIDC issuer that can vouch for the identity of
# Kubernetes ServiceAccounts running inside it. Same underlying AWS
# mechanism (an IAM OIDC identity provider + AssumeRoleWithWebIdentity), two
# unrelated identity sources for two unrelated purposes — one authenticates
# CI jobs, this one authenticates in-cluster Pods.
# ---------------------------------------------------------------------------

data "tls_certificate" "cluster" {
  url = aws_eks_cluster.this.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "cluster" {
  url             = aws_eks_cluster.this.identity[0].oidc[0].issuer
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.cluster.certificates[0].sha1_fingerprint]
}

# ---------------------------------------------------------------------------
# Node group IAM role (instance-profile style — the whole EC2 instance gets
# these permissions, not scoped to individual pods). AmazonEKS_CNI_Policy is
# attached here as the node-level baseline the VPC CNI needs to function at
# all; it moves to a pod-scoped IRSA role below for the actual addon
# configuration, which is the more precise, least-privilege path.
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "node_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "node" {
  name               = "${var.cluster_name}-eks-node-role"
  assume_role_policy = data.aws_iam_policy_document.node_assume.json
}

resource "aws_iam_role_policy_attachment" "node_worker" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "node_ecr_readonly" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_iam_role_policy_attachment" "node_cni" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

# ---------------------------------------------------------------------------
# Managed node group — 2x t3.large on-demand, AL2023. Sized for the VPC CNI's
# pod-per-node ceiling, not CPU/memory: t3.medium caps out at 17 pods and
# t3.large at 35. See docs/known-gotchas.md for how that ceiling surfaces.
# ---------------------------------------------------------------------------

resource "aws_eks_node_group" "this" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "${var.cluster_name}-node-group"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = var.subnet_ids

  ami_type       = "AL2023_x86_64_STANDARD"
  instance_types = ["t3.large"]
  capacity_type  = "ON_DEMAND"

  scaling_config {
    desired_size = 2
    min_size     = 2
    max_size     = 4
  }

  depends_on = [
    aws_iam_role_policy_attachment.node_worker,
    aws_iam_role_policy_attachment.node_ecr_readonly,
    aws_iam_role_policy_attachment.node_cni,
  ]
}

# ---------------------------------------------------------------------------
# IRSA: VPC CNI addon role — scoped to exactly the ServiceAccount the CNI
# DaemonSet runs as (kube-system:aws-node), not the whole node.
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "cni_irsa_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.cluster.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(aws_iam_openid_connect_provider.cluster.url, "https://", "")}:sub"
      values   = ["system:serviceaccount:kube-system:aws-node"]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(aws_iam_openid_connect_provider.cluster.url, "https://", "")}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "cni_irsa" {
  name               = "${var.cluster_name}-vpc-cni-irsa"
  assume_role_policy = data.aws_iam_policy_document.cni_irsa_assume.json
}

resource "aws_iam_role_policy_attachment" "cni_irsa" {
  role       = aws_iam_role.cni_irsa.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

# ---------------------------------------------------------------------------
# IRSA: EBS CSI driver role — scoped to kube-system:ebs-csi-controller-sa
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "ebs_csi_irsa_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.cluster.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(aws_iam_openid_connect_provider.cluster.url, "https://", "")}:sub"
      values   = ["system:serviceaccount:kube-system:ebs-csi-controller-sa"]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(aws_iam_openid_connect_provider.cluster.url, "https://", "")}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ebs_csi_irsa" {
  name               = "${var.cluster_name}-ebs-csi-irsa"
  assume_role_policy = data.aws_iam_policy_document.ebs_csi_irsa_assume.json
}

resource "aws_iam_role_policy_attachment" "ebs_csi_irsa" {
  role       = aws_iam_role.ebs_csi_irsa.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

# ---------------------------------------------------------------------------
# IRSA: Loki role — scoped to monitoring:loki (the Loki chart's default
# ServiceAccount name/namespace), and to just the one bucket it needs.
# Unlike the CNI/EBS-CSI roles above (which use an AWS-managed policy),
# this one is a custom least-privilege policy since there's no AWS-managed
# policy for "read/write objects in exactly this bucket".
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "loki_irsa_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.cluster.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(aws_iam_openid_connect_provider.cluster.url, "https://", "")}:sub"
      values   = ["system:serviceaccount:monitoring:loki"]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(aws_iam_openid_connect_provider.cluster.url, "https://", "")}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "loki_irsa" {
  name               = "${var.cluster_name}-loki-irsa"
  assume_role_policy = data.aws_iam_policy_document.loki_irsa_assume.json
}

data "aws_iam_policy_document" "loki_bucket_access" {
  statement {
    sid    = "LokiBucketAccess"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:ListBucket",
    ]
    resources = [
      var.loki_bucket_arn,
      "${var.loki_bucket_arn}/*",
    ]
  }
}

resource "aws_iam_role_policy" "loki_irsa" {
  name   = "loki-s3-access"
  role   = aws_iam_role.loki_irsa.id
  policy = data.aws_iam_policy_document.loki_bucket_access.json
}

# ---------------------------------------------------------------------------
# EKS managed add-ons. Depend on the node group so their pods have somewhere
# to schedule — creating them before any nodes exist just leaves them
# waiting/unhealthy until compute shows up.
# ---------------------------------------------------------------------------

resource "aws_eks_addon" "vpc_cni" {
  cluster_name             = aws_eks_cluster.this.name
  addon_name               = "vpc-cni"
  service_account_role_arn = aws_iam_role.cni_irsa.arn

  depends_on = [aws_eks_node_group.this]
}

resource "aws_eks_addon" "coredns" {
  cluster_name = aws_eks_cluster.this.name
  addon_name   = "coredns"

  depends_on = [aws_eks_node_group.this]
}

resource "aws_eks_addon" "kube_proxy" {
  cluster_name = aws_eks_cluster.this.name
  addon_name   = "kube-proxy"

  depends_on = [aws_eks_node_group.this]
}

resource "aws_eks_addon" "ebs_csi" {
  cluster_name             = aws_eks_cluster.this.name
  addon_name               = "aws-ebs-csi-driver"
  service_account_role_arn = aws_iam_role.ebs_csi_irsa.arn

  depends_on = [aws_eks_node_group.this]
}

# ---------------------------------------------------------------------------
# CloudWatch Container Insights — a second, INDEPENDENT observability path
# alongside Prometheus/Grafana/Loki. The point is not redundancy for its own
# sake: CloudWatch is an external observer that survives failures of the
# in-cluster stack, and on managed EKS it can reach control-plane data that
# Prometheus structurally cannot scrape.
#
# Container Insights publishes metrics as embedded metric format (EMF) THROUGH
# CloudWatch Logs, so this log group exists even with container log shipping
# switched off. Left to the agent to create, it defaults to never-expire and
# is unowned by Terraform -- which is exactly how /aws/eks/railhead-dev/cluster
# accumulated 1.51 GB across every session before anyone noticed.
#
# DESTROY ORDER: Terraform destroys in reverse dependency order, so the add-on
# must depend on the log group. Otherwise the group is deleted first, the agent
# is still running and immediately recreates it, and the recreated group -- now
# unmanaged -- outlives the cluster. The 1-day retention is the backstop if
# that ordering ever fails anyway.
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "container_insights_performance" {
  name              = "/aws/containerinsights/${var.cluster_name}/performance"
  retention_in_days = 1
}

# ---------------------------------------------------------------------------
# IRSA: CloudWatch agent — scoped to amazon-cloudwatch:cloudwatch-agent.
#
# That ServiceAccount name was read off the running cluster after installing
# the add-on, not taken from documentation. Getting it wrong does not fail
# loudly: the agent falls back to the node instance role, which has no
# CloudWatch permissions, and every pod stays Running while silently
# publishing nothing. Confirmed by watching it happen -- the agent logged
# `AccessDeniedException ... assumed-role/railhead-dev-eks-node-role ... is
# not authorized to perform: logs:PutLogEvents` and dropped 968 datapoints
# per flush while reporting healthy.
#
# This role lives in module.eks, not module.iam, and that placement is
# load-bearing. Its trust policy references the cluster's OIDC issuer URL,
# which contains a cluster ID that changes on every destroy/recreate. A role
# persisted in module.iam would survive teardown still trusting a provider
# that no longer exists, and IRSA would fail silently on the next rebuild.
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "cloudwatch_agent_irsa_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.cluster.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(aws_iam_openid_connect_provider.cluster.url, "https://", "")}:sub"
      values   = ["system:serviceaccount:amazon-cloudwatch:cloudwatch-agent"]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(aws_iam_openid_connect_provider.cluster.url, "https://", "")}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "cloudwatch_agent_irsa" {
  name               = "${var.cluster_name}-cloudwatch-agent-irsa"
  assume_role_policy = data.aws_iam_policy_document.cloudwatch_agent_irsa_assume.json
}

resource "aws_iam_role_policy_attachment" "cloudwatch_agent_irsa" {
  role       = aws_iam_role.cloudwatch_agent_irsa.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

# Every optional workload this add-on ships defaults to enabled. Six are turned
# off deliberately:
#   containerLogs      - Loki already owns logs. Shipping them twice doubles
#                        ingestion cost for no added signal.
#   kubeStateMetrics   - kube-prometheus-stack already runs one.
#   nodeExporter       - so does this. Both would be straight duplicates.
#   applicationSignals - APM tracing, out of scope; needs workload annotations
#                        to do anything, so it would be inert cost.
#   dcgmExporter       - NVIDIA GPU telemetry. No GPU nodes.
#   neuronMonitor      - AWS Neuron telemetry. No Inferentia/Trainium nodes.
# containerInsights stays on: that is the cluster/node/pod metric pipeline this
# whole exercise exists for.
resource "aws_eks_addon" "cloudwatch_observability" {
  cluster_name             = aws_eks_cluster.this.name
  addon_name               = "amazon-cloudwatch-observability"
  addon_version            = var.cloudwatch_observability_addon_version
  service_account_role_arn = aws_iam_role.cloudwatch_agent_irsa.arn

  configuration_values = jsonencode({
    containerLogs      = { enabled = false }
    kubeStateMetrics   = { enabled = false }
    nodeExporter       = { enabled = false }
    applicationSignals = { enabled = false }
    dcgmExporter       = { enabled = false }
    neuronMonitor      = { enabled = false }
    containerInsights  = { enabled = true }
  })

  # The node group dependency is not cosmetic: without nodes the DaemonSet has
  # nowhere to schedule and the add-on settles into DEGRADED on a fresh apply.
  depends_on = [
    aws_eks_node_group.this,
    aws_cloudwatch_log_group.container_insights_performance,
  ]
}

# ---------------------------------------------------------------------------
# CloudWatch alarms.
#
# NONE of these carry alarm_actions, and that is deliberate rather than
# unfinished. Alertmanager already owns notification routing for this project,
# and a second delivery path is a second thing that can drift out of sync --
# the same reasoning that keeps AUTO_REMEDIATE_ALERTS as the single source of
# truth for what gets auto-remediated instead of splitting it across
# Alertmanager's routing tree. These alarms are state you can query and see in
# the console; they are not a pager.
#
# Thresholds below are derived from values observed on this cluster, recorded
# in each comment, rather than copied from documentation.
# ---------------------------------------------------------------------------

# META-MONITORING. The remediator watches railhead-api; nothing watched the
# remediator. It runs a single replica by design (its state lives in pod
# labels, so restarting it loses nothing) -- but a single replica that dies
# stays dead, and the in-cluster stack cannot reliably alert on its own
# failure. Prometheus and Alertmanager run in the same cluster and would be
# subject to the same outage. CloudWatch is an external observer that survives
# the failure it reports on, which is the actual argument for running both
# systems rather than picking one.
#
# service_number_of_running_pods scopes to a single Kubernetes Service.
# namespace_number_of_running_pods was rejected: it counts api + worker +
# postgres + remediator together, so losing the remediator would barely move
# it and any threshold low enough to catch that would also fire on a routine
# api rollout.
#
# treat_missing_data = "breaching" is the load-bearing setting. If the pod
# disappears entirely the metric stops publishing rather than reporting zero,
# and the CloudWatch default would park the alarm in INSUFFICIENT_DATA --
# silent for precisely the failure it exists to catch.
#
# Observed baseline: 1.0, stable.
# EXPECTED at teardown: this goes to ALARM when the pod is destroyed. Correct
# behaviour, not a fault.
resource "aws_cloudwatch_metric_alarm" "remediator_down" {
  alarm_name        = "${var.cluster_name}-remediator-down"
  alarm_description = "railhead-remediator has no running pods. Nothing else watches the remediator; Prometheus cannot reliably alert on a failure inside its own cluster."

  namespace   = "ContainerInsights"
  metric_name = "service_number_of_running_pods"
  dimensions = {
    ClusterName = aws_eks_cluster.this.name
    Service     = "railhead-remediator"
    Namespace   = "railhead"
  }

  statistic           = "Minimum"
  comparison_operator = "LessThanThreshold"
  threshold           = 1
  period              = 60
  evaluation_periods  = 3
  datapoints_to_alarm = 3
  treat_missing_data  = "breaching"
}

# INFRASTRUCTURE. Threshold anchored to kubelet's own behaviour, not a round
# number: the default nodefs.available eviction signal is 10% free, so kubelet
# begins evicting pods at roughly 90% utilization. Alarming at 80% leaves a
# ~10 point margin to react before eviction starts.
#
# Maximum, not Average: with only ClusterName as a dimension, Average blends
# both nodes and every filesystem on them, so one filling disk would be hidden
# by healthy ones. Maximum surfaces the worst case, which is the entire point
# of a disk-pressure alarm.
#
# Observed baseline: avg 11.8%, max 40.3%.
resource "aws_cloudwatch_metric_alarm" "node_filesystem_high" {
  alarm_name        = "${var.cluster_name}-node-filesystem-high"
  alarm_description = "A node filesystem is above 80% utilization. kubelet begins evicting pods near 90% (nodefs.available default of 10% free)."

  namespace   = "ContainerInsights"
  metric_name = "node_filesystem_utilization"
  dimensions = {
    ClusterName = aws_eks_cluster.this.name
  }

  statistic           = "Maximum"
  comparison_operator = "GreaterThanThreshold"
  threshold           = 80
  period              = 300
  evaluation_periods  = 2
  treat_missing_data  = "missing"
}

# CONTROL PLANE. This is data Prometheus structurally cannot reach on managed
# EKS -- the API server and etcd are AWS-operated and unscrapeable -- which
# makes it the clearest example of CloudWatch filling a real capability gap
# rather than duplicating a Grafana panel.
#
# Honest framing: this is a growth-anomaly detector, not a capacity alarm.
# EKS's etcd limit is 8 GB and this cluster sits at 27 MB, so a threshold
# anchored to the real limit would never fire and would be decorative. 100 MB
# is ~3.7x the observed baseline: above anything normal workload churn
# produces, low enough to catch a controller looping on object creation or a
# runaway CRD long before etcd itself is under stress.
#
# Observed baseline: 28,270,592 bytes (27.0 MB), flat.
resource "aws_cloudwatch_metric_alarm" "apiserver_storage_growth" {
  alarm_name        = "${var.cluster_name}-apiserver-storage-growth"
  alarm_description = "etcd object storage exceeded 100 MB against a ~27 MB baseline. Indicates abnormal object accumulation, not capacity pressure -- the EKS limit is 8 GB."

  namespace   = "ContainerInsights"
  metric_name = "apiserver_storage_size_bytes"
  dimensions = {
    ClusterName = aws_eks_cluster.this.name
  }

  statistic           = "Maximum"
  comparison_operator = "GreaterThanThreshold"
  threshold           = 104857600
  period              = 300
  evaluation_periods  = 2
  treat_missing_data  = "missing"
}
