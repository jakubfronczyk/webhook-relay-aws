output "alb_sg_id" {
  description = "Security group for the ALB"
  value       = aws_security_group.alb.id
}

output "api_sg_id" {
  description = "Security group for the api ECS service"
  value       = aws_security_group.api.id
}

output "worker_sg_id" {
  description = "Security group for the worker ECS service"
  value       = aws_security_group.worker.id
}

output "rds_sg_id" {
  description = "Security group for the RDS instance"
  value       = aws_security_group.rds.id
}
