terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # Partial configuration: bucket and region come from bootstrap/ via just init.
  backend "s3" {
    key          = "webhook-relay/terraform.tfstate"
    encrypt      = true
    use_lockfile = true
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

  project_name                  = var.project_name
  vpc_cidr                      = var.vpc_cidr
  public_subnet_cidr            = var.public_subnet_cidr
  public_subnet_secondary_cidr  = var.public_subnet_secondary_cidr
  private_subnet_cidr           = var.private_subnet_cidr
  private_subnet_secondary_cidr = var.private_subnet_secondary_cidr
}

module "security" {
  source = "./modules/security"

  vpc_id       = module.networking.vpc_id
  project_name = var.project_name
  api_port     = var.api_port
  db_port      = var.db_port
}

module "observability" {
  source = "./modules/observability"

  project_name       = var.project_name
  monthly_budget_usd = var.monthly_budget_usd
  alert_emails       = var.alert_emails
}

module "messaging" {
  source = "./modules/messaging"

  project_name = var.project_name

  visibility_timeout_seconds = var.queue_visibility_timeout_seconds
  max_receive_count          = var.queue_max_receive_count
}

module "registry" {
  source = "./modules/registry"

  project_name = var.project_name
}

module "database" {
  source = "./modules/database"

  project_name       = var.project_name
  private_subnet_ids = module.networking.private_subnet_ids
  rds_sg_id          = module.security.rds_sg_id

  db_port        = var.db_port
  instance_class = var.db_instance_class
}

module "alb" {
  source = "./modules/alb"

  project_name      = var.project_name
  vpc_id            = module.networking.vpc_id
  public_subnet_ids = module.networking.public_subnet_ids
  alb_sg_id         = module.security.alb_sg_id
  api_port          = var.api_port
}

module "ecs" {
  source = "./modules/ecs"

  project_name = var.project_name
  aws_region   = var.aws_region

  private_subnet_ids = module.networking.private_subnet_ids
  api_sg_id          = module.security.api_sg_id
  worker_sg_id       = module.security.worker_sg_id
  target_group_arn   = module.alb.target_group_arn

  image_urls = module.registry.repository_urls
  image_tag  = var.image_tag

  queue_url  = module.messaging.queue_url
  queue_arn  = module.messaging.queue_arn
  queue_name = module.messaging.queue_name

  db_host       = module.database.endpoint
  db_port       = var.db_port
  db_name       = module.database.db_name
  db_username   = module.database.username
  db_secret_arn = module.database.master_user_secret_arn

  api_port           = var.api_port
  worker_concurrency = var.worker_concurrency

  alb_arn_suffix          = module.alb.alb_arn_suffix
  target_group_arn_suffix = module.alb.target_group_full_name
  worker_max_tasks        = var.worker_max_tasks
  worker_backlog_per_task = var.worker_backlog_per_task

  # The listener must exist before the api service can register targets.
  depends_on = [module.alb]
}
