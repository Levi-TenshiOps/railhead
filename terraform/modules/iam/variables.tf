variable "github_org" {
  description = "GitHub organization/user that owns the repo allowed to assume this role"
  type        = string
  default     = "Levi-TenshiOps"
}

variable "github_repo" {
  description = "GitHub repository allowed to assume this role"
  type        = string
  default     = "railhead"
}

variable "state_bucket_arn" {
  description = "ARN of the S3 bucket holding Terraform state"
  type        = string
}

variable "lock_table_arn" {
  description = "ARN of the DynamoDB table used for Terraform state locking"
  type        = string
}
