variable "project_name" {
  description = "Project name, used as the cluster name and the prefix for every resource here"
  type        = string
}

variable "aws_region" {
  description = "Region, needed by the awslogs driver and passed to both containers"
  type        = string
}

variable "services" {
  description = "Service names. Drives the log groups and task roles; the task definitions and services are written out explicitly."
  type        = list(string)
  default     = ["api", "worker"]
}

# Networking and security
variable "private_subnet_ids" {
  description = "Subnets both services run in. Neither has a public IP."
  type        = list(string)
}

variable "api_sg_id" {
  description = "Security group for api tasks. Ingress from the ALB only."
  type        = string
}

variable "worker_sg_id" {
  description = "Security group for worker tasks. Zero ingress rules."
  type        = string
}

variable "target_group_arn" {
  description = "Target group the api service registers its task IPs with"
  type        = string
}

# Images
variable "image_urls" {
  description = "Service name to ECR repository URL"
  type        = map(string)
}

variable "image_tag" {
  description = "Image tag to deploy. Matches what just push produced."
  type        = string
  default     = "latest"
}

# Dependencies
variable "queue_url" {
  description = "Delivery queue URL, passed to both services as QUEUE_URL"
  type        = string
}

variable "queue_arn" {
  description = "Delivery queue ARN. Both task role policies are scoped to this one queue."
  type        = string
}

variable "db_host" {
  description = "RDS endpoint hostname"
  type        = string
}

variable "db_port" {
  description = "RDS port"
  type        = number
  default     = 5432
}

variable "db_name" {
  description = "Database name"
  type        = string
}

variable "db_username" {
  description = "Database username. The password arrives separately, from Secrets Manager."
  type        = string
}

variable "db_secret_arn" {
  description = "ARN of the RDS-managed secret. The execution role can read this one ARN, and the password reaches the container as DB_PASSWORD without ever appearing in the task definition."
  type        = string
}

# Sizing
variable "api_cpu" {
  description = "api task CPU units. 256 is a quarter vCPU."
  type        = number
  default     = 256
}

variable "api_memory" {
  description = "api task memory in MiB. Fargate only accepts certain cpu/memory pairs."
  type        = number
  default     = 512
}

variable "worker_cpu" {
  description = "worker task CPU units"
  type        = number
  default     = 256
}

variable "worker_memory" {
  description = "worker task memory in MiB"
  type        = number
  default     = 512
}

variable "api_desired_count" {
  description = "api tasks to run. Two, so the service survives losing one AZ."
  type        = number
  default     = 2
}

variable "worker_desired_count" {
  description = "worker tasks to run. One is the floor autoscaling scales up from in Phase 5."
  type        = number
  default     = 1
}

variable "api_port" {
  description = "Container port the api listens on. Must match the target group and the api security group."
  type        = number
  default     = 8080
}

# Worker tuning
variable "worker_concurrency" {
  description = "Concurrent deliveries per worker task. Also caps the poll batch size, since a message received beyond this limit waits with its visibility timeout already running."
  type        = number
  default     = 8
}

variable "backoff_base" {
  description = "First retry delay, doubling per receive. 30s here; the compose stack compresses it to 2s so a demo finishes in a minute."
  type        = string
  default     = "30s"
}

variable "delivery_timeout" {
  description = "Per-POST timeout. Multiplied by the number of subscribers on one event type, this must stay under the queue's visibility timeout."
  type        = string
  default     = "5s"
}

variable "log_retention_days" {
  description = "CloudWatch log retention. The default is never expire, which bills forever."
  type        = number
  default     = 7
}
