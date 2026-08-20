variable "vpc_id" {
  description = "ID of the VPC the security groups belong to"
  type        = string
}

variable "project_name" {
  description = "Project name, used as the prefix for security group names and Name tags"
  type        = string
}

variable "api_port" {
  description = "Container port the api service listens on, and the ALB target group port"
  type        = number
  default     = 8080
}

variable "db_port" {
  description = "Port the RDS PostgreSQL instance listens on"
  type        = number
  default     = 5432
}
