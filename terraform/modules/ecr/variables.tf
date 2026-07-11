variable "repository_names" {
  description = "List of ECR repository names to create, one per container image"
  type        = list(string)
  default     = ["railhead-app"]
}
