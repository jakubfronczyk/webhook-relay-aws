# RDS PostgreSQL, private, with an RDS-managed master password that Terraform never sees.
# The settings marked below are demo-correct and production-wrong.

resource "aws_db_subnet_group" "main" {
  name       = "${var.project_name}-db-subnet-group"
  subnet_ids = var.private_subnet_ids

  # RDS requires two availability zones even for a single-AZ instance.
  description = "Private subnets. The instance has no route to or from the internet."

  tags = {
    Name = "${var.project_name}-db-subnet-group"
  }
}

resource "aws_db_instance" "main" {
  identifier = "${var.project_name}-db"

  engine = "postgres"
  # Major version only; RDS selects the current minor release.
  engine_version = var.engine_version
  instance_class = var.instance_class

  allocated_storage = var.allocated_storage
  storage_type      = "gp3"
  # Free with the default key, and not enableable later without a snapshot and restore.
  storage_encrypted = true

  db_name  = var.db_name
  username = var.db_username

  # RDS creates the password and owns the secret, so the value never enters Terraform state.
  manage_master_user_password = true

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [var.rds_sg_id]
  # No public IP and no route to the internet gateway.
  publicly_accessible = false

  port = var.db_port

  # ---- demo-correct, production-wrong ----

  deletion_protection        = false # production: true, but it makes terraform destroy fail
  skip_final_snapshot        = true  # production: false, to leave a recoverable snapshot
  backup_retention_period    = 0     # production: 7 days or more
  auto_minor_version_upgrade = true  # production: false, patched in a chosen window
  apply_immediately          = true  # production: false, changes land in the window

  # Absent for cost: multi_az, performance_insights_enabled, enhanced monitoring.

  tags = {
    Name = "${var.project_name}-db"
  }
}
