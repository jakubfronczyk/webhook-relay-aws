output "vpc_id" {
  description = "ID of the VPC"
  value       = module.networking.vpc_id
}

output "public_subnet_ids" {
  description = "IDs of the public subnets (ALB)"
  value       = module.networking.public_subnet_ids
}

output "private_subnet_ids" {
  description = "IDs of the private subnets (ECS tasks, RDS)"
  value       = module.networking.private_subnet_ids
}

output "security_group_ids" {
  description = "The four security groups in the chain"
  value = {
    alb    = module.security.alb_sg_id
    api    = module.security.api_sg_id
    worker = module.security.worker_sg_id
    rds    = module.security.rds_sg_id
  }
}

output "queue_url" {
  description = "Delivery queue URL, passed to both services as QUEUE_URL"
  value       = module.messaging.queue_url
}

output "dlq_url" {
  description = "Dead-letter queue URL, for inspecting exhausted messages"
  value       = module.messaging.dlq_url
}

output "ecr_repository_urls" {
  description = "Push targets for just push"
  value       = module.registry.repository_urls
}

output "database_endpoint" {
  description = "RDS hostname. Resolvable only from inside the VPC."
  value       = module.database.endpoint
}
