variable "github_repo_url" {
  description = "URL of the GitHub repo ArgoCD syncs the railhead-app chart from"
  type        = string
  default     = "https://github.com/Levi-TenshiOps/railhead"
}

variable "argocd_chart_version" {
  description = "Version of the argo-cd Helm chart to install"
  type        = string
  default     = "10.1.3"
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

variable "kube_prometheus_stack_chart_version" {
  description = "Version of the kube-prometheus-stack Helm chart to install"
  type        = string
  default     = "87.17.0"
}

variable "loki_chart_version" {
  description = "Version of the Loki Helm chart to install"
  type        = string
  default     = "7.1.0"
}

variable "alloy_chart_version" {
  description = "Version of the Grafana Alloy Helm chart to install"
  type        = string
  default     = "1.10.1"
}

variable "loki_bucket_name" {
  description = "Name of the S3 bucket used for Loki chunk/index storage"
  type        = string
}

variable "loki_irsa_role_arn" {
  description = "ARN of the IRSA role Loki assumes to access its S3 bucket"
  type        = string
}
