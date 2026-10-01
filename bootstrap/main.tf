# Creates the bucket the root configuration keeps its state in. State here stays local on
# purpose: a backend cannot create itself, and one bucket is recoverable with terraform import.

terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project = var.project_name
      Purpose = "terraform-state"
    }
  }
}

variable "aws_region" {
  description = "Region of the state bucket, independent of where the platform runs"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Prefix for the bucket name"
  type        = string
  default     = "webhook-relay"
}

data "aws_caller_identity" "current" {}

# The account ID makes the name globally unique without a random suffix.
resource "aws_s3_bucket" "state" {
  bucket = "${var.project_name}-tfstate-${data.aws_caller_identity.current.account_id}"

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id

  versioning_configuration {
    status = "Enabled"
  }
}

# S3 has applied this by default since 2023; declared so the setting is reviewable.
resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket = aws_s3_bucket.state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

output "state_bucket" {
  description = "Passed to the root configuration by just init"
  value       = aws_s3_bucket.state.bucket
}

output "region" {
  description = "Passed to the root configuration by just init"
  value       = var.aws_region
}
