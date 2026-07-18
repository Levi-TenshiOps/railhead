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

# Trust policy: only GitHub Actions runs on the main branch of this repo
# can assume this role — tightened from an initial wide-open
# "repo:<org>/<repo>:*" (any branch/tag/PR) now that a real CI workflow
# exists to test against. PR runs never reach this trust condition at all
# since ci.yml doesn't request credentials for pull_request events.
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
      values   = ["repo:${var.github_org}/${var.github_repo}:ref:refs/heads/main"]
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

data "aws_caller_identity" "current" {}

# Loki's chunk/index storage. Unlike the Terraform state bucket, this one
# is genuinely disposable — force_destroy is intentional here, since log
# data losing prevent_destroy protection is the correct choice (nothing
# else in this project depends on old logs surviving a bucket teardown).
resource "aws_s3_bucket" "loki_chunks" {
  bucket        = "railhead-loki-chunks-${data.aws_caller_identity.current.account_id}"
  force_destroy = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "loki_chunks" {
  bucket = aws_s3_bucket.loki_chunks.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "loki_chunks" {
  bucket = aws_s3_bucket.loki_chunks.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
