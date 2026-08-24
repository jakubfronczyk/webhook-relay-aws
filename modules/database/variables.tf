variable "project_name" {
  description = "Project name, used as the prefix for the instance identifier and Name tags"
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnet IDs for the DB subnet group. RDS requires at least two AZs."
  type        = list(string)
}

variable "rds_sg_id" {
  description = "Security group for the instance. Accepts 5432 from the api and worker groups only."
  type        = string
}

variable "engine_version" {
  description = "PostgreSQL major version. RDS picks the current minor release."
  type        = string
  default     = "16"
}

variable "instance_class" {
  description = "Instance size. db.t3.micro is ~$0.017/h and is the bottleneck past roughly 5,000 events."
  type        = string
  default     = "db.t3.micro"
}

variable "allocated_storage" {
  description = "Storage in GB. 20 is the gp3 minimum."
  type        = number
  default     = 20
}

variable "db_name" {
  description = "Name of the database created on the instance"
  type        = string
  default     = "relay"
}

variable "db_username" {
  description = "Master username. The password is generated and owned by RDS, never by Terraform."
  type        = string
  default     = "relay"
}

variable "db_port" {
  description = "Port the instance listens on. Must match the rds security group rules."
  type        = number
  default     = 5432
}
