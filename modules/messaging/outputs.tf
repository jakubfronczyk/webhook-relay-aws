output "queue_url" {
  description = "Delivery queue URL. Passed to both services as QUEUE_URL."
  value       = aws_sqs_queue.deliveries.url
}

output "queue_arn" {
  description = "Delivery queue ARN, for the task role policies that scope SQS access to this one queue"
  value       = aws_sqs_queue.deliveries.arn
}

output "queue_name" {
  description = "Delivery queue name. The QueueName dimension of every CloudWatch SQS metric, so the worker's backlog-per-task autoscaling policy needs it."
  value       = aws_sqs_queue.deliveries.name
}

output "dlq_url" {
  description = "Dead-letter queue URL, for inspecting exhausted messages"
  value       = aws_sqs_queue.dlq.url
}

output "dlq_arn" {
  description = "Dead-letter queue ARN"
  value       = aws_sqs_queue.dlq.arn
}
