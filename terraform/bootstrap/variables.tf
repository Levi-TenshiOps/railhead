variable "aws_region" {
  description = "AWS region for the Terraform state backend resources"
  type        = string
  default     = "us-east-1"
}

variable "aws_account_id" {
  description = "AWS account ID, used to make the state bucket name globally unique"
  type        = string
}

variable "lock_table_name" {
  description = "Name of the DynamoDB table used for Terraform state locking"
  type        = string
  default     = "railhead-tfstate-lock"
}
