variable "project_name" {
  description = "Project name, used as the prefix for load balancer and target group names"
  type        = string
}

variable "vpc_id" {
  description = "VPC the target group registers targets in"
  type        = string
}

variable "public_subnet_ids" {
  description = "Public subnets for the load balancer nodes. At least two availability zones."
  type        = list(string)
}

variable "alb_sg_id" {
  description = "Security group for the load balancer. The only group accepting traffic from the internet."
  type        = string
}

variable "api_port" {
  description = "Container port the api listens on. Must match the api security group's ingress rule."
  type        = number
  default     = 8080
}
