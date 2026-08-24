# The delivery queue and its dead-letter queue. SQS owns redelivery, the attempt ceiling and
# the DLQ; the worker owns the backoff curve. Every number here has a counterpart in
# elasticmq.conf, which the local demo runs against.

resource "aws_sqs_queue" "deliveries" {
  name = "${var.project_name}-deliveries"

  # Must exceed DELIVERY_TIMEOUT multiplied by the subscribers on one event type, since the
  # worker delivers to them serially. At 5s that is six subscribers before this ceiling.
  visibility_timeout_seconds = var.visibility_timeout_seconds

  # Outer bound on the message, distinct from the retry ceiling.
  message_retention_seconds = var.message_retention_seconds

  # Long-poll default for callers that do not pass WaitTimeSeconds.
  receive_wait_time_seconds = 20

  # maxReceiveCount counts receives, not failures, so a crash after receiving burns one.
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq.arn
    maxReceiveCount     = var.max_receive_count
  })

  tags = {
    Name = "${var.project_name}-deliveries"
  }
}

resource "aws_sqs_queue" "dlq" {
  name = "${var.project_name}-deliveries-dlq"

  # Fourteen days, the SQS maximum, so a poison message survives long enough to inspect.
  message_retention_seconds = var.dlq_message_retention_seconds

  tags = {
    Name = "${var.project_name}-deliveries-dlq"
  }
}

# The redrive_policy above points one way and grants nothing; without this, any queue in the
# account may nominate this DLQ.
resource "aws_sqs_queue_redrive_allow_policy" "dlq" {
  queue_url = aws_sqs_queue.dlq.id

  redrive_allow_policy = jsonencode({
    redrivePermission = "byQueue"
    sourceQueueArns   = [aws_sqs_queue.deliveries.arn]
  })
}
