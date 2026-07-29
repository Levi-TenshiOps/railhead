variable "aws_region" {
  description = "AWS region for the dev environment"
  type        = string
  default     = "us-east-1"
}

variable "github_token" {
  description = "Fine-grained GitHub PAT (read-only, repo-scoped) for ArgoCD's git access. The repo is public, so this is not required to clone -- it keeps ArgoCD on authenticated GitHub rate limits and preserves the path if the repo is ever made private again."
  type        = string
  sensitive   = true
}

variable "slack_webhook_url" {
  description = "Slack incoming webhook URL Alertmanager posts alert notifications to"
  type        = string
  sensitive   = true
}
