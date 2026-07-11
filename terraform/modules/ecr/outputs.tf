output "repository_urls" {
  description = "Map of repository name to its pull/push URL"
  value       = { for name, repo in aws_ecr_repository.this : name => repo.repository_url }
}

output "repository_arns" {
  description = "Map of repository name to its ARN"
  value       = { for name, repo in aws_ecr_repository.this : name => repo.arn }
}
