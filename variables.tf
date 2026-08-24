variable "aws_region" {
  description = "AWS region to deploy resources"
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Environment name (e.g., dev, staging, prod)"
  type        = string
  default     = "dev"
}

variable "project_name" {
  description = "Name of the project"
  type        = string
  default     = "webhook-relay"
}

# Cost guardrail
variable "monthly_budget_usd" {
  description = "Monthly spend ceiling for the account, in USD"
  type        = number
  default     = 20
}

variable "alert_emails" {
  description = "Email addresses that receive budget notifications"
  type        = list(string)
}

# Networking
variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidr" {
  description = "CIDR block for the first public subnet (AZ a)"
  type        = string
  default     = "10.0.1.0/24"
}

variable "public_subnet_secondary_cidr" {
  description = "CIDR block for the second public subnet (AZ b)"
  type        = string
  default     = "10.0.2.0/24"
}

variable "private_subnet_cidr" {
  description = "CIDR block for the first private subnet (AZ a)"
  type        = string
  default     = "10.0.11.0/24"
}

variable "private_subnet_secondary_cidr" {
  description = "CIDR block for the second private subnet (AZ b)"
  type        = string
  default     = "10.0.12.0/24"
}

# AWS Credentials (optional - can use environment variables or AWS CLI config instead)
variable "aws_access_key_id" {
  description = "AWS Access Key ID (optional - can use environment variables or AWS CLI config)"
  type        = string
  default     = null
  sensitive   = true
}

variable "aws_secret_access_key" {
  description = "AWS Secret Access Key (optional - can use environment variables or AWS CLI config)"
  type        = string
  default     = null
  sensitive   = true
}

variable "aws_session_token" {
  description = "AWS Session Token for temporary credentials (optional)"
  type        = string
  default     = null
  sensitive   = true
}

# Messaging
# These two must stay in step with elasticmq.conf, which is what the local demo runs against.
variable "queue_visibility_timeout_seconds" {
  description = "How long a received message stays hidden. Must exceed worst-case delivery time."
  type        = number
  default     = 30
}

variable "queue_max_receive_count" {
  description = "Receives allowed before SQS moves the message to the dead-letter queue"
  type        = number
  default     = 4
}

# Database
variable "db_instance_class" {
  description = "RDS instance size"
  type        = string
  default     = "db.t3.micro"
}

# Ports. Declared once here and passed to every module that needs them: the security group
# rules, the load balancer target group, the container port, and the database. Left as
# per-module defaults they drift, and the failure is a service nothing can reach with no
# plan-time error.
variable "api_port" {
  description = "Port the api container listens on, and the ALB target group port"
  type        = number
  default     = 8080
}

variable "db_port" {
  description = "Port the RDS instance listens on"
  type        = number
  default     = 5432
}

# Compute
variable "image_tag" {
  description = "Image tag the services run. Matches what just push produced."
  type        = string
  default     = "latest"
}

variable "worker_concurrency" {
  description = "Concurrent deliveries per worker task"
  type        = number
  default     = 8
}
