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

  depends_on = [aws_iam_role_policy_attachment.cluster_policy]
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
