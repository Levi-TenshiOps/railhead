variable "aws_region" {
  description = "AWS region for the dev environment"
  type        = string
  default     = "us-east-1"
}

variable "github_token" {
  description = "Fine-grained GitHub PAT (read-only, repo-scoped) so ArgoCD can clone the private railhead repo"
  type        = string
  sensitive   = true
}

variable "slack_webhook_url" {
  description = "Slack incoming webhook URL Alertmanager posts alert notifications to"
  type        = string
  sensitive   = true
}
