# Four security groups and their rules.
#
# The groups deliberately hold no inline ingress/egress blocks. Every rule is a separate
# aws_vpc_security_group_{ingress,egress}_rule resource, because the chain requires the ALB
# group to reference the api group and the api group to reference the ALB group. Expressed
# as inline blocks that is a cycle in the dependency graph and Terraform refuses to plan.
# Rule resources point into the groups instead, so no group ever references another.
#
# Terraform removes the allow-all egress rule AWS attaches to every new group. Egress here
# is therefore only what is written below, and rds has none at all.

resource "aws_security_group" "alb" {
  name        = "${var.project_name}-alb-sg"
  description = "Public entry point. Accepts HTTP from the internet, forwards to the api service."
  vpc_id      = var.vpc_id

  tags = {
    Name = "${var.project_name}-alb-sg"
  }
}

resource "aws_security_group" "api" {
  name        = "${var.project_name}-api-sg"
  description = "api service. Reachable only from the ALB. Talks to RDS and to AWS APIs."
  vpc_id      = var.vpc_id

  tags = {
    Name = "${var.project_name}-api-sg"
  }
}

resource "aws_security_group" "worker" {
  name        = "${var.project_name}-worker-sg"
  description = "worker service. No ingress rules by design, nothing can open a connection to it."
  vpc_id      = var.vpc_id

  tags = {
    Name = "${var.project_name}-worker-sg"
  }
}

resource "aws_security_group" "rds" {
  name        = "${var.project_name}-rds-sg"
  description = "PostgreSQL. Accepts connections from the api and worker groups only. No egress."
  vpc_id      = var.vpc_id

  tags = {
    Name = "${var.project_name}-rds-sg"
  }
}

# ---------------------------------------------------------------------------
# alb-sg
# ---------------------------------------------------------------------------

resource "aws_vpc_security_group_ingress_rule" "alb_http_from_internet" {
  security_group_id = aws_security_group.alb.id
  description       = "HTTP from anywhere. The only public ingress in the platform."

  cidr_ipv4   = "0.0.0.0/0"
  ip_protocol = "tcp"
  from_port   = 80
  to_port     = 80

  tags = {
    Name = "${var.project_name}-alb-http-in"
  }
}

resource "aws_vpc_security_group_egress_rule" "alb_to_api" {
  security_group_id = aws_security_group.alb.id
  description       = "Forward to the api service on its container port."

  referenced_security_group_id = aws_security_group.api.id
  ip_protocol                  = "tcp"
  from_port                    = var.api_port
  to_port                      = var.api_port

  tags = {
    Name = "${var.project_name}-alb-to-api"
  }
}

# ---------------------------------------------------------------------------
# api-sg
# ---------------------------------------------------------------------------

resource "aws_vpc_security_group_ingress_rule" "api_from_alb" {
  security_group_id = aws_security_group.api.id
  description       = "Only the ALB may reach the api service."

  referenced_security_group_id = aws_security_group.alb.id
  ip_protocol                  = "tcp"
  from_port                    = var.api_port
  to_port                      = var.api_port

  tags = {
    Name = "${var.project_name}-api-from-alb"
  }
}

resource "aws_vpc_security_group_egress_rule" "api_to_rds" {
  security_group_id = aws_security_group.api.id
  description       = "Persist events and subscriptions."

  referenced_security_group_id = aws_security_group.rds.id
  ip_protocol                  = "tcp"
  from_port                    = var.db_port
  to_port                      = var.db_port

  tags = {
    Name = "${var.project_name}-api-to-rds"
  }
}

resource "aws_vpc_security_group_egress_rule" "api_to_aws_apis" {
  security_group_id = aws_security_group.api.id
  description       = "SQS SendMessage and Secrets Manager. Public AWS endpoints, reached via NAT."

  cidr_ipv4   = "0.0.0.0/0"
  ip_protocol = "tcp"
  from_port   = 443
  to_port     = 443

  tags = {
    Name = "${var.project_name}-api-to-aws-apis"
  }
}

# ---------------------------------------------------------------------------
# worker-sg. No ingress rule exists for this group, and that is the claim.
# ---------------------------------------------------------------------------

resource "aws_vpc_security_group_egress_rule" "worker_to_rds" {
  security_group_id = aws_security_group.worker.id
  description       = "Record delivery attempts."

  referenced_security_group_id = aws_security_group.rds.id
  ip_protocol                  = "tcp"
  from_port                    = var.db_port
  to_port                      = var.db_port

  tags = {
    Name = "${var.project_name}-worker-to-rds"
  }
}

resource "aws_vpc_security_group_egress_rule" "worker_to_internet" {
  security_group_id = aws_security_group.worker.id
  description       = "Deliver webhooks to arbitrary subscriber URLs, plus AWS APIs. Via NAT."

  cidr_ipv4   = "0.0.0.0/0"
  ip_protocol = "tcp"
  from_port   = 443
  to_port     = 443

  tags = {
    Name = "${var.project_name}-worker-to-internet"
  }
}

# ---------------------------------------------------------------------------
# rds-sg. Two ingress rules, no egress. Postgres never initiates connections.
# ---------------------------------------------------------------------------

resource "aws_vpc_security_group_ingress_rule" "rds_from_api" {
  security_group_id = aws_security_group.rds.id
  description       = "api service connections."

  referenced_security_group_id = aws_security_group.api.id
  ip_protocol                  = "tcp"
  from_port                    = var.db_port
  to_port                      = var.db_port

  tags = {
    Name = "${var.project_name}-rds-from-api"
  }
}

resource "aws_vpc_security_group_ingress_rule" "rds_from_worker" {
  security_group_id = aws_security_group.rds.id
  description       = "worker service connections."

  referenced_security_group_id = aws_security_group.worker.id
  ip_protocol                  = "tcp"
  from_port                    = var.db_port
  to_port                      = var.db_port

  tags = {
    Name = "${var.project_name}-rds-from-worker"
  }
}
