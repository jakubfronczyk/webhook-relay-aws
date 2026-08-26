# The cluster, both services, and three IAM roles. Two explicit service blocks rather than a
# reusable submodule, since the services differ in IAM, scaling signal and load balancer.
#
# The execution role is used by the ECS agent before the container starts, to pull the image
# and resolve secrets, and is shared. A task role is assumed by the process inside the
# container and differs per service.

resource "aws_ecs_cluster" "main" {
  name = var.project_name

  setting {
    # Required: RunningTaskCount is only emitted by Container Insights, and the worker
    # policy divides by it. Billed per task.
    name  = "containerInsights"
    value = "enabled"
  }

  tags = {
    Name = var.project_name
  }
}

# ---------------------------------------------------------------------------
# Logs
# ---------------------------------------------------------------------------

# The awslogs driver does not create the group, and a task whose logging fails at startup
# leaves no log explaining it. Retention is set because the default is never to expire.
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

# Covers ECR pull and CloudWatch Logs write. Hand-writing it means discovering that
# ecr:GetAuthorizationToken has to be granted on "*".
resource "aws_iam_role_policy_attachment" "execution_managed" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# Reading the database password is not in that managed policy, and is scoped to one secret.
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

# The api can only enqueue; it cannot read or delete a message.
data "aws_iam_policy_document" "api_task" {
  statement {
    actions   = ["sqs:SendMessage"]
    resources = [var.queue_arn]
  }
}

# The worker can only consume, so a bug in it cannot manufacture events. Removing
# ChangeMessageVisibility fails silently: retries fall back to the queue's fixed timeout.
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

# ECS Exec, for `aws ecs execute-command`. The permissions belong on the task role, because
# the SSM agent runs inside the container.
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
  # The password is absent here and arrives through the secrets block, so it never appears in
  # the task definition, the console, or the task-start event stream.
  common_environment = [
    { name = "DB_HOST", value = var.db_host },
    { name = "DB_PORT", value = tostring(var.db_port) },
    { name = "DB_USER", value = var.db_username },
    { name = "DB_NAME", value = var.db_name },
    { name = "QUEUE_URL", value = var.queue_url },
    { name = "AWS_REGION", value = var.aws_region },
  ]

  # :password:: selects one key from the JSON secret; the empty fields mean the current version.
  common_secrets = [
    { name = "DB_PASSWORD", valueFrom = "${var.db_secret_arn}:password::" },
  ]
}

resource "aws_ecs_task_definition" "api" {
  family                   = "${var.project_name}-api"
  requires_compatibilities = ["FARGATE"]
  # The only mode Fargate supports; each task gets its own ENI, and so its own security group.
  network_mode       = "awsvpc"
  cpu                = var.api_cpu
  memory             = var.api_memory
  execution_role_arn = aws_iam_role.execution.arn
  task_role_arn      = aws_iam_role.task["api"].arn

  # Fargate defaults to X86_64; an arm64 image on it fails at task start with
  # "exec format error". ARM64 is also about 20% cheaper.
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

    # No portMappings; the worker listens on no port.

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
    # The ALB reaches the task over the VPC local route; outbound goes via the NAT gateway.
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = var.target_group_arn
    container_name   = "api"
    container_port   = var.api_port
  }

  # Covers migrations and the first connection to a cold RDS instance, which would otherwise
  # fail health checks and loop.
  health_check_grace_period_seconds = 60

  # A new task must pass health checks before an old one is drained.
  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200

  # A revision that never reaches a steady state is otherwise retried forever. Rollback
  # returns the service to the last revision that worked.
  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  # Autoscaling owns desired_count after the first apply.
  lifecycle {
    ignore_changes = [desired_count]
  }

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

  # No load balancer and no health check; the queue depth is the backpressure signal.

  # A worker being briefly absent delays delivery and loses nothing, so a deploy replaces
  # rather than doubles.
  deployment_minimum_healthy_percent = 0
  deployment_maximum_percent         = 100

  # With no health check, a steady state means the task stayed running, which still catches a
  # wrong-architecture image, a missing task role, or an unreachable database.
  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  lifecycle {
    ignore_changes = [desired_count]
  }

  tags = {
    Name = "${var.project_name}-worker"
  }
}

# ---------------------------------------------------------------------------
# Autoscaling
# ---------------------------------------------------------------------------

resource "aws_appautoscaling_target" "api" {
  service_namespace  = "ecs"
  resource_id        = "service/${aws_ecs_cluster.main.name}/${aws_ecs_service.api.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  min_capacity       = var.api_min_tasks
  max_capacity       = var.api_max_tasks
}

resource "aws_appautoscaling_target" "worker" {
  service_namespace  = "ecs"
  resource_id        = "service/${aws_ecs_cluster.main.name}/${aws_ecs_service.worker.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  min_capacity       = var.worker_min_tasks
  max_capacity       = var.worker_max_tasks
}

# Requests per target, not CPU: the api waits on Postgres and SQS, so CPU moves late.
resource "aws_appautoscaling_policy" "api_requests" {
  name               = "${var.project_name}-api-requests-per-target"
  policy_type        = "TargetTrackingScaling"
  service_namespace  = aws_appautoscaling_target.api.service_namespace
  resource_id        = aws_appautoscaling_target.api.resource_id
  scalable_dimension = aws_appautoscaling_target.api.scalable_dimension

  target_tracking_scaling_policy_configuration {
    target_value = var.api_requests_per_target

    predefined_metric_specification {
      predefined_metric_type = "ALBRequestCountPerTarget"
      # The only predefined metric needing a label; the target group cannot be inferred.
      resource_label = "${var.alb_arn_suffix}/${var.target_group_arn_suffix}"
    }

    scale_in_cooldown  = 120
    scale_out_cooldown = 30
  }
}

# Backlog per task, not queue depth: an absolute depth does not scale with fleet size and
# oscillates. The numerator is the visible count only, since in-flight messages already have
# a task working on them.
resource "aws_appautoscaling_policy" "worker_backlog" {
  name               = "${var.project_name}-worker-backlog-per-task"
  policy_type        = "TargetTrackingScaling"
  service_namespace  = aws_appautoscaling_target.worker.service_namespace
  resource_id        = aws_appautoscaling_target.worker.resource_id
  scalable_dimension = aws_appautoscaling_target.worker.scalable_dimension

  target_tracking_scaling_policy_configuration {
    target_value = var.worker_backlog_per_task

    customized_metric_specification {
      metrics {
        id    = "backlog"
        label = "Backlog per task"
        # IF guards the division; RunningTaskCount reports 0 during a cold start.
        expression  = "visible / IF(tasks > 0, tasks, 1)"
        return_data = true
      }

      metrics {
        id          = "visible"
        return_data = false

        metric_stat {
          metric {
            namespace   = "AWS/SQS"
            metric_name = "ApproximateNumberOfMessagesVisible"

            dimensions {
              name  = "QueueName"
              value = var.queue_name
            }
          }
          stat = "Average"
        }
      }

      metrics {
        id          = "tasks"
        return_data = false

        metric_stat {
          metric {
            namespace   = "ECS/ContainerInsights"
            metric_name = "RunningTaskCount"

            dimensions {
              name  = "ClusterName"
              value = aws_ecs_cluster.main.name
            }

            dimensions {
              name  = "ServiceName"
              value = aws_ecs_service.worker.name
            }
          }
          stat = "Average"
        }
      }
    }

    # Slow in, fast out: scaling in early strands a backlog, scaling out early costs cents.
    scale_in_cooldown  = 180
    scale_out_cooldown = 30
  }
}
