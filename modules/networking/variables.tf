variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
}

variable "environment" {
  description = "Environment name used for tagging"
  type        = string
}

variable "public_subnet_cidr" {
  description = "CIDR block for the first public subnet"
  type        = string
}

variable "public_subnet_secondary_cidr" {
  description = "CIDR block for the second public subnet"
  type        = string
}

variable "private_subnet_cidr" {
  description = "CIDR block for the first private subnet"
  type        = string
}

variable "private_subnet_secondary_cidr" {
  description = "CIDR block for the second private subnet"
  type        = string
}

