variable "cluster_name" {
  description = "Name used to tag subnets for EKS auto-discovery (kubernetes.io/cluster/<name>)"
  type        = string
  default     = "railhead-dev"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}
