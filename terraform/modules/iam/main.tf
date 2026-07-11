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

# GitHub rotates the certificate behind its OIDC endpoint from time to
# time, which changes its thumbprint. Fetching it live via tls_certificate
# (instead of hardcoding a thumbprint string) means this keeps working
# across those rotations without a manual update here.
data "tls_certificate" "github_actions" {
  url = "https://token.actions.githubusercontent.com/.well-known/openid-configuration"
}

resource "aws_iam_openid_connect_provider" "github_actions" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.github_actions.certificates[0].sha1_fingerprint]
}

# Trust policy: only GitHub Actions runs from this repo (any branch,
# tag, or PR) can assume this role. Once the CI workflow exists, tighten
# the "sub" condition to a specific ref, e.g.
# "repo:${var.github_org}/${var.github_repo}:ref:refs/heads/main", so
# only pushes to main can deploy instead of every branch/PR.
data "aws_iam_policy_document" "github_actions_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github_actions.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_org}/${var.github_repo}:*"]
    }
  }
}

resource "aws_iam_role" "github_actions_deploy" {
  name               = "${var.github_repo}-github-actions-deploy"
  assume_role_policy = data.aws_iam_policy_document.github_actions_trust.json
}

# Deliberately minimal: only what's needed to run terraform plan/apply
# against the existing state backend today. This grows incrementally as
# EKS/ECR/etc. modules are added later — CI does not get AdministratorAccess
# just to make things easy now.
data "aws_iam_policy_document" "terraform_state_access" {
  statement {
    sid    = "TerraformStateBucketAccess"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:ListBucket",
    ]
    resources = [
      var.state_bucket_arn,
      "${var.state_bucket_arn}/*",
    ]
  }

  statement {
    sid    = "TerraformStateLockAccess"
    effect = "Allow"
    actions = [
      "dynamodb:GetItem",
      "dynamodb:PutItem",
      "dynamodb:DeleteItem",
    ]
    resources = [var.lock_table_arn]
  }
}

resource "aws_iam_role_policy" "terraform_state_access" {
  name   = "terraform-state-access"
  role   = aws_iam_role.github_actions_deploy.id
  policy = data.aws_iam_policy_document.terraform_state_access.json
}
