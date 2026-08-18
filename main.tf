terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region     = var.aws_region
  access_key = var.aws_access_key_id
  secret_key = var.aws_secret_access_key
  token      = var.aws_session_token

  default_tags {
    tags = {
      Environment = var.environment
      Project     = var.project_name
    }
  }
}

module "networking" {
  source = "./modules/networking"

  environment                   = var.environment
  project_name                  = var.project_name
  vpc_cidr                      = var.vpc_cidr
  public_subnet_cidr            = var.public_subnet_cidr
  public_subnet_secondary_cidr  = var.public_subnet_secondary_cidr
  private_subnet_cidr           = var.private_subnet_cidr
  private_subnet_secondary_cidr = var.private_subnet_secondary_cidr
}
