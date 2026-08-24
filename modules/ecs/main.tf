# The cluster, both services, and the three IAM roles they need.
#
# One module with two explicit service blocks rather than a reusable ecs-service submodule.
# The two services differ in scaling signal, IAM permissions, and load balancer attachment,
# one of them having none at all, so a submodule would be mostly conditionals. This reads
# top to bottom.
#
# Three roles, not two, and the distinction is the most commonly muddled thing in ECS:
#
#   execution role  is used by the ECS agent, BEFORE the container starts. It pulls the
#                   image and resolves secrets. Shared by both services because both do
#                   exactly the same two things.
#   task role       is assumed by the process INSIDE the container. This is where
#                   sqs:SendMessage lives, and it is different for each service, which is
#                   the whole point of running them separately.

resource "aws_ecs_cluster" "main" {
  name = var.project_name

  setting {
    # Per-service CloudWatch metrics. Free; the paid tier is Container Insights.
    name  = "containerInsights"
    value = "disabled"
  }

  tags = {
    Name = var.project_name
  }
}

# ---------------------------------------------------------------------------
# Logs
# ---------------------------------------------------------------------------

# Without an explicit group the awslogs driver fails to create one and the task dies at
# startup with no log to explain why, because the thing that would have logged it is the
# logging. Retention is set because "never expire" is the default and it bills forever.
resource "aws_cloudwatch_log_group" "service" {
  for_each = toset(var.services)

  name              = "/ecs/${var.project_name}/${each.key}"
  retention_in_days = var.log_retention_days

  tags = {
    Name = "/ecs/${var.project_name}/${each.key}"
  }
}

# ---------------------------------------------------------------------------
# IAM: the execution role, shared
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "ecs_tasks_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "execution" {
  name               = "${var.project_name}-execution-role"
  description        = "Used by the ECS agent before the container starts: pull the image, resolve secrets."
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json

  tags = {
    Name = "${var.project_name}-execution-role"
  }
}

# The AWS-managed policy covers ECR pull and CloudWatch Logs write. Hand-writing it is a
# common way to spend an afternoon discovering ecr:GetAuthorizationToken must be on "*".
resource "aws_iam_role_policy_attachment" "execution_managed" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# Reading the database password is NOT in that managed policy, and it is scoped to the one
# secret rather than to Secrets Manager as a whole.
data "aws_iam_policy_document" "execution_secrets" {
  statement {
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [var.db_secret_arn]
  }
}

resource "aws_iam_role_policy" "execution_secrets" {
  name   = "read-db-secret"
  role   = aws_iam_role.execution.id
  policy = data.aws_iam_policy_document.execution_secrets.json
}

# ---------------------------------------------------------------------------
# IAM: one task role per service. These are deliberately different.
# ---------------------------------------------------------------------------

resource "aws_iam_role" "task" {
  for_each = toset(var.services)

  name               = "${var.project_name}-${each.key}-task-role"
  description        = "Assumed by the ${each.key} process itself."
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json

  tags = {
    Name = "${var.project_name}-${each.key}-task-role"
  }
}

# The api only ever puts messages on the queue. It cannot read or delete one.
data "aws_iam_policy_document" "api_task" {
  statement {
    actions   = ["sqs:SendMessage"]
    resources = [var.queue_arn]
  }
}

# The worker only ever consumes. It cannot enqueue, so a bug in the worker cannot manufacture
# events. ChangeMessageVisibility is what the backoff curve is made of, and its absence would
# fail silently: retries would fall back to the queue's fixed timeout and the growing interval
# the README documents would quietly not happen.
data "aws_iam_policy_document" "worker_task" {
  statement {
    actions = [
      "sqs:ReceiveMessage",
      "sqs:DeleteMessage",
      "sqs:ChangeMessageVisibility",
      "sqs:GetQueueAttributes",
    ]
    resources = [var.queue_arn]
  }
}

resource "aws_iam_role_policy" "task" {
  for_each = {
    api    = data.aws_iam_policy_document.api_task.json
    worker = data.aws_iam_policy_document.worker_task.json
  }

  name   = "${each.key}-queue-access"
  role   = aws_iam_role.task[each.key].id
  policy = each.value
}

# ECS Exec, so `aws ecs execute-command` can open a shell in a running task. This is how the
# "nothing can reach the worker" claim gets demonstrated rather than asserted: exec into a
# task and watch a connection to the worker time out. The permissions belong on the task
# role, not the execution role, because the SSM agent runs inside the container.
data "aws_iam_policy_document" "exec_channel" {
  statement {
    actions = [
      "ssmmessages:CreateControlChannel",
      "ssmmessages:CreateDataChannel",
      "ssmmessages:OpenControlChannel",
      "ssmmessages:OpenDataChannel",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "exec_channel" {
  for_each = toset(var.services)

  name   = "ecs-exec"
  role   = aws_iam_role.task[each.key].id
  policy = data.aws_iam_policy_document.exec_channel.json
}

# ---------------------------------------------------------------------------
# Task definitions
# ---------------------------------------------------------------------------

locals {
  # Shared by both containers. The password is absent on purpose: it arrives through the
  # secrets block below, so it never appears in the task definition, the ECS console, or the
  # CloudWatch event stream that records every task start.
  common_environment = [
    { name = "DB_HOST", value = var.db_host },
    { name = "DB_PORT", value = tostring(var.db_port) },
    { name = "DB_USER", value = var.db_username },
    { name = "DB_NAME", value = var.db_name },
    { name = "QUEUE_URL", value = var.queue_url },
    { name = "AWS_REGION", value = var.aws_region },
  ]

  # :password:: selects one key out of the JSON document RDS writes. The empty fields are the
  # version stage and version id, and omitting them means "current".
  common_secrets = [
    { name = "DB_PASSWORD", valueFrom = "${var.db_secret_arn}:password::" },
  ]
}

resource "aws_ecs_task_definition" "api" {
  family                   = "${var.project_name}-api"
  requires_compatibilities = ["FARGATE"]
  # awsvpc is the only network mode Fargate supports. Each task gets its own ENI and private
  # IP, which is what allows a security group to be attached to a task at all.
  network_mode       = "awsvpc"
  cpu                = var.api_cpu
  memory             = var.api_memory
  execution_role_arn = aws_iam_role.execution.arn
  task_role_arn      = aws_iam_role.task["api"].arn

  # Fargate defaults to X86_64. The images are built natively on an arm64 laptop, and running
  # one on the wrong architecture fails at task start with "exec format error". ARM64 Fargate
  # is also about 20% cheaper.
  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "ARM64"
  }

  container_definitions = jsonencode([{
    name      = "api"
    image     = "${var.image_urls["api"]}:${var.image_tag}"
    essential = true

    portMappings = [{ containerPort = var.api_port, protocol = "tcp" }]

    environment = concat(local.common_environment, [
      { name = "LISTEN_ADDR", value = ":${var.api_port}" },
    ])
    secrets = local.common_secrets

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.service["api"].name
        "awslogs-region"        = var.aws_region
        "awslogs-stream-prefix" = "ecs"
      }
    }
  }])

  tags = {
    Name = "${var.project_name}-api"
  }
}

resource "aws_ecs_task_definition" "worker" {
  family                   = "${var.project_name}-worker"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.worker_cpu
  memory                   = var.worker_memory
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task["worker"].arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "ARM64"
  }

  container_definitions = jsonencode([{
    name      = "worker"
    essential = true
    image     = "${var.image_urls["worker"]}:${var.image_tag}"

    # No portMappings. The worker listens on nothing, which is what lets its security group
    # have zero ingress rules.

    environment = concat(local.common_environment, [
      { name = "WORKER_CONCURRENCY", value = tostring(var.worker_concurrency) },
      { name = "POLL_BATCH_SIZE", value = tostring(var.worker_concurrency) },
      { name = "BACKOFF_BASE", value = var.backoff_base },
      { name = "DELIVERY_TIMEOUT", value = var.delivery_timeout },
    ])
    secrets = local.common_secrets

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.service["worker"].name
        "awslogs-region"        = var.aws_region
        "awslogs-stream-prefix" = "ecs"
      }
    }
  }])

  tags = {
    Name = "${var.project_name}-worker"
  }
}

# ---------------------------------------------------------------------------
# Services
# ---------------------------------------------------------------------------

resource "aws_ecs_service" "api" {
  name            = "${var.project_name}-api"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.api.arn
  desired_count   = var.api_desired_count
  launch_type     = "FARGATE"

  enable_execute_command = true

  network_configuration {
    subnets         = var.private_subnet_ids
    security_groups = [var.api_sg_id]
    # No public IP. The ALB is in the public subnets and reaches the task over the VPC's
    # local route; the task reaches AWS APIs outbound through the NAT gateway.
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = var.target_group_arn
    container_name   = "api"
    container_port   = var.api_port
  }

  # Migrations run at startup and the first connection to a cold RDS instance is slow. Without
  # this grace period ECS starts health checking immediately, fails the task, and replaces it
  # forever in a loop that looks like a broken image.
  health_check_grace_period_seconds = 60

  # Roll one task at a time while keeping the old one serving: 100/200 with two tasks means a
  # new one must pass health checks before an old one is drained.
  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200

  tags = {
    Name = "${var.project_name}-api"
  }
}

resource "aws_ecs_service" "worker" {
  name            = "${var.project_name}-worker"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.worker.arn
  desired_count   = var.worker_desired_count
  launch_type     = "FARGATE"

  enable_execute_command = true

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = [var.worker_sg_id]
    assign_public_ip = false
  }

  # No load_balancer block and no health check grace period, because there is no health check.
  # ECS considers a worker task healthy while its process is running, which is correct: the
  # queue is the backpressure signal, not an endpoint.

  # 0/100 rather than 100/200. A worker being briefly absent delays delivery and loses nothing,
  # so a deploy replaces rather than doubles, and does not need spare capacity to proceed.
  deployment_minimum_healthy_percent = 0
  deployment_maximum_percent         = 100

  tags = {
    Name = "${var.project_name}-worker"
  }
}
