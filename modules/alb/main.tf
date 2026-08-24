# The only resource in this platform with a public address. It terminates internet
# connections and decides which api tasks are healthy enough to receive traffic.

resource "aws_lb" "main" {
  name               = "${var.project_name}-alb"
  load_balancer_type = "application"
  internal           = false

  # Public subnets in two AZs. An ALB requires at least two, and it places one node in each.
  subnets         = var.public_subnet_ids
  security_groups = [var.alb_sg_id]

  enable_deletion_protection = false # production: true, but it makes terraform destroy fail

  # Above the api's own timeouts, so a slow request is ended by the application.
  idle_timeout = 60

  tags = {
    Name = "${var.project_name}-alb"
  }
}

# target_type must be "ip": awsvpc tasks have their own ENI and private IP, and there is no
# instance to register.
resource "aws_lb_target_group" "api" {
  name        = "${var.project_name}-api-tg"
  target_type = "ip"
  vpc_id      = var.vpc_id
  port        = var.api_port
  protocol    = "HTTP"

  health_check {
    path     = "/healthz"
    protocol = "HTTP"
    matcher  = "200"

    # 2 x 15s, so an unhealthy task leaves rotation in about 30 seconds.
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }

  # Draining window for a task being removed, matched to the api's shutdown timeout.
  deregistration_delay = 30

  tags = {
    Name = "${var.project_name}-api-tg"
  }
}

# HTTP only; HTTPS needs an ACM certificate and a domain. Production is a :443 listener with
# this one redirecting to it.
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.api.arn
  }
}
