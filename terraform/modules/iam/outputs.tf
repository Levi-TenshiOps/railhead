output "github_actions_role_arn" {
  description = "ARN of the IAM role GitHub Actions assumes via OIDC"
  value       = aws_iam_role.github_actions_deploy.arn
}

output "github_actions_role_name" {
  description = "Name of the IAM role GitHub Actions assumes via OIDC"
  value       = aws_iam_role.github_actions_deploy.name
}
