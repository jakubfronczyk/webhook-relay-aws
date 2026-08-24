# The public entry point. One load balancer, one target group, one listener.
#
# The ALB is the only resource in this platform with a public address, and it exists for two
# reasons that are easy to conflate. It terminates connections from the internet so the api
# tasks never hold one directly, and it decides which tasks are healthy enough to receive
# traffic. The second is the one that makes deploys safe.

resource "aws_lb" "main" {
  name               = "${var.project_name}-alb"
  load_balancer_type = "application"
  internal           = false

  # Public subnets in two AZs. An ALB requires at least two, and it places one node in each.
  subnets         = var.public_subnet_ids
  security_groups = [var.alb_sg_id]

  # Production: true, so an accidental destroy is refused. Here it would make teardown fail,
  # and teardown is the cost guardrail.
  enable_deletion_protection = false

  # Longer than the api's own read timeout, so a slow request is ended by the application
  # rather than cut off by the load balancer with no log line explaining it.
  idle_timeout = 60

  tags = {
    Name = "${var.project_name}-alb"
  }
}

# target_type = "ip" is not optional. Fargate tasks use the awsvpc network mode and each task
# gets its own ENI and private IP; there is no instance to register, so the "instance" target
# type cannot express them.
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

    # 2 x 15s means an unhealthy task leaves rotation in about 30 seconds, and a new one
    # joins after two passes. Tighter than this and a slow cold start looks like a failure.
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }

  # How long the ALB waits before finishing off connections to a task being removed. It is
  # the other half of the api honouring SIGTERM: ECS sends the signal, the ALB stops sending
  # new requests, and both need to finish before the task dies.
  deregistration_delay = 30

  tags = {
    Name = "${var.project_name}-api-tg"
  }
}

# HTTP only. HTTPS needs an ACM certificate, which needs a domain and DNS validation. The
# security story for a webhook *sender* is the HMAC signature the subscriber verifies, which
# works identically over HTTP. The production form is a :443 listener with this one
# redirecting to it, and that is about fifteen lines.
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.api.arn
  }
}
