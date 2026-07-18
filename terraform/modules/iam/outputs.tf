output "github_actions_role_arn" {
  description = "ARN of the IAM role GitHub Actions assumes via OIDC"
  value       = aws_iam_role.github_actions_deploy.arn
}

output "github_actions_role_name" {
  description = "Name of the IAM role GitHub Actions assumes via OIDC"
  value       = aws_iam_role.github_actions_deploy.name
}

output "loki_chunks_bucket_name" {
  description = "Name of the S3 bucket used for Loki chunk/index storage"
  value       = aws_s3_bucket.loki_chunks.bucket
}

output "loki_chunks_bucket_arn" {
  description = "ARN of the S3 bucket used for Loki chunk/index storage"
  value       = aws_s3_bucket.loki_chunks.arn
}
