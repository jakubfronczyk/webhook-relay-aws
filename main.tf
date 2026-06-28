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

# VPC and Networking
resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "nexussync-vpc"
  }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = true

  tags = {
    Name = "nexussync-public-subnet"
  }
}

resource "aws_subnet" "public_secondary" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.2.0/24"
  availability_zone = data.aws_availability_zones.available.names[1]

  tags = {
    Name = "nexussync-public-subnet-2"
  }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "nexussync-igw"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name = "nexussync-public-rt"
  }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "public_secondary" {
  subnet_id      = aws_subnet.public_secondary.id
  route_table_id = aws_route_table.public.id
}

# Database Infrastructure
resource "aws_db_subnet_group" "main" {
  name       = "nexussync-db-subnet-group"
  subnet_ids = [aws_subnet.public.id, aws_subnet.public_secondary.id]

  tags = {
    Name = "nexussync-db-subnet-group"
  }
}

resource "aws_security_group" "database" {
  name        = "nexussync-database-sg"
  description = "Security group for database"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "nexussync-database-sg"
  }
}

resource "aws_db_instance" "postgres" {
  identifier     = "nexussync-db"
  engine         = "postgres"
  engine_version = "15"
  instance_class = "db.t3.micro"

  allocated_storage = 20
  storage_type      = "gp2"

  db_name  = "nexussync"
  username = "admin1"
  password = "password123"

  vpc_security_group_ids = [aws_security_group.database.id]
  db_subnet_group_name   = aws_db_subnet_group.main.name

  publicly_accessible = true
  skip_final_snapshot = true

  tags = {
    Name = "nexussync-database"
  }
}

# Container Infrastructure
resource "aws_ecs_cluster" "main" {
  name = "nexussync-cluster"

  tags = {
    Name = "nexussync-cluster"
  }
}

resource "aws_security_group" "api" {
  name        = "nexussync-api-sg"
  description = "Security group for API containers"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port   = 0
    to_port     = 65535
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "nexussync-api-sg"
  }
}

resource "aws_ecs_task_definition" "api" {
  family                   = "nexussync-api"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.ecs_execution.arn

  container_definitions = jsonencode([
    {
      name  = "api"
      image = "nginx:alpine"
      portMappings = [
        {
          containerPort = 80
          hostPort      = 80
          protocol      = "tcp"
        }
      ]
      environment = [
        {
          name  = "DB_HOST"
          value = aws_db_instance.postgres.endpoint
        },
        {
          name  = "DB_NAME"
          value = "nexussync"
        },
        {
          name  = "DB_USER"
          value = "admin1"
        },
        {
          name  = "DB_PASSWORD"
          value = "password123"
        }
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.api.name
          awslogs-region        = var.aws_region
          awslogs-stream-prefix = "ecs"
        }
      }
      healthCheck = {
        command  = ["CMD-SHELL", "curl -f http://localhost:80/health || exit 1"]
        interval = 30
        timeout  = 5
        retries  = 3
      }
    }
  ])
}

resource "aws_ecs_service" "api" {
  name            = "nexussync-api"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.api.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = [aws_subnet.public.id]
    security_groups  = [aws_security_group.api.id]
    assign_public_ip = true
  }

  tags = {
    Name = "nexussync-api"
  }
}

# IAM Roles
resource "aws_iam_role" "ecs_execution" {
  name = "nexussync-ecs-execution-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_execution" {
  role       = aws_iam_role.ecs_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# CloudWatch Logs
resource "aws_cloudwatch_log_group" "api" {
  name              = "/ecs/nexussync-api"
  retention_in_days = 7

  tags = {
    Name = "nexussync-api-logs"
  }
}

# Data Sources
data "aws_availability_zones" "available" {
  state = "available"
}
