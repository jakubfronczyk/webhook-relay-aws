output "repository_urls" {
  description = "Service name to repository URL, the image reference the task definitions use"
  value       = { for name, repo in aws_ecr_repository.service : name => repo.repository_url }
}

output "repository_arns" {
  description = "Service name to repository ARN, for scoping the execution role's ECR pull permission"
  value       = { for name, repo in aws_ecr_repository.service : name => repo.arn }
}
