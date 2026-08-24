output "endpoint" {
  description = "Instance hostname. Resolvable only inside the VPC, which is what enable_dns_support in the networking module is for."
  value       = aws_db_instance.main.address
}

output "port" {
  description = "Port the instance listens on"
  value       = aws_db_instance.main.port
}

output "db_name" {
  description = "Database name, for assembling DATABASE_URL in the task definitions"
  value       = aws_db_instance.main.db_name
}

output "username" {
  description = "Master username, for assembling DATABASE_URL in the task definitions"
  value       = aws_db_instance.main.username
}

output "master_user_secret_arn" {
  description = "ARN of the RDS-managed Secrets Manager secret holding the password. The ECS task definitions reference this rather than the value, and the execution role is granted read on this ARN alone."
  value       = aws_db_instance.main.master_user_secret[0].secret_arn
}
