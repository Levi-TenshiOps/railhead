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
