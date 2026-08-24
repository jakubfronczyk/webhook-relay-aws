output "cluster_name" {
  description = "Cluster name, for aws ecs commands and the Phase 5 autoscaling resource id"
  value       = aws_ecs_cluster.main.name
}

output "api_service_name" {
  description = "api service name"
  value       = aws_ecs_service.api.name
}

output "worker_service_name" {
  description = "worker service name. The durability demo sets its desired count to zero at peak backlog."
  value       = aws_ecs_service.worker.name
}

output "execution_role_arn" {
  description = "Shared execution role. Pulls images and resolves the database secret."
  value       = aws_iam_role.execution.arn
}

output "task_role_arns" {
  description = "Service name to task role ARN. Two roles with deliberately different permissions: the api can only send, the worker can only consume."
  value       = { for name, role in aws_iam_role.task : name => role.arn }
}

output "log_group_names" {
  description = "Service name to CloudWatch log group"
  value       = { for name, lg in aws_cloudwatch_log_group.service : name => lg.name }
}
