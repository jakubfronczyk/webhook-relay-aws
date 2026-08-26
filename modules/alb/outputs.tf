output "dns_name" {
  description = "Public hostname of the load balancer. The URL the demo curls."
  value       = aws_lb.main.dns_name
}

output "target_group_arn" {
  description = "Target group the api service registers its tasks with"
  value       = aws_lb_target_group.api.arn
}

output "listener_arn" {
  description = "HTTP listener. The api service must wait for this to exist before it can register targets."
  value       = aws_lb_listener.http.arn
}

output "target_group_full_name" {
  description = "Dimension value for the ALB's CloudWatch metrics, which the api's request-count autoscaling policy needs in Phase 5"
  value       = aws_lb_target_group.api.arn_suffix
}

output "alb_arn_suffix" {
  description = "Dimension value for the load balancer's CloudWatch metrics, and half of the ALBRequestCountPerTarget resource label"
  value       = aws_lb.main.arn_suffix
}
