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
