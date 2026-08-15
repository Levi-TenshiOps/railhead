variable "cluster_name" {
  description = "Name of the EKS cluster"
  type        = string
  default     = "railhead-dev"
}

variable "kubernetes_version" {
  description = "Kubernetes version for the EKS control plane"
  type        = string
  default     = "1.34"
}

variable "subnet_ids" {
  description = "Subnet IDs for the EKS control plane and node group (private subnets)"
  type        = list(string)
}

variable "loki_bucket_arn" {
  description = "ARN of the S3 bucket used for Loki chunk/index storage (from the iam module)"
  type        = string
}

# Pinned explicitly, unlike the four core add-ons above it, which float on
# whatever EKS defaults to for the cluster version. Those are AWS-owned
# components whose behaviour we don't configure; this one carries a
# configuration_values payload whose schema changes between major versions --
# v6 renamed the "enhanced" Container Insights toggle to a legacy/OTEL split,
# for example. Pinning means a schema change surfaces as a deliberate version
# bump rather than a silent config drift on the next rebuild.
variable "cloudwatch_observability_addon_version" {
  description = "Pinned version of the amazon-cloudwatch-observability EKS add-on"
  type        = string
  default     = "v6.5.0-eksbuild.1"
}
