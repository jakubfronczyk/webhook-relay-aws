# The delivery queue and its dead-letter queue.
#
# These two resources are the durability half of the delivery contract. SQS owns redelivery,
# the attempt ceiling, and where an exhausted message ends up. The worker owns only the
# backoff curve and the HMAC, because SQS has no exponential-backoff setting to configure.
#
# Every number here has a counterpart in elasticmq.conf, which is what the local demo runs
# against. If the two drift, the retry curve the README documents stops being the one that
# runs in AWS.

resource "aws_sqs_queue" "deliveries" {
  name = "${var.project_name}-deliveries"

  # Must exceed worst-case delivery time. The worker caps each POST at DELIVERY_TIMEOUT and
  # runs WORKER_CONCURRENCY of them per task, so a message can never still be in progress
  # when this expires. Set it too low and SQS hands the message to a second worker while the
  # first is still POSTing, and the subscriber sees a duplicate nothing asked for.
  visibility_timeout_seconds = var.visibility_timeout_seconds

  # How long an undelivered message survives on the queue at all. Distinct from the retry
  # ceiling: retries end at max_receive_count, this is the outer bound on the message.
  message_retention_seconds = var.message_retention_seconds

  # Queue-level default for long polling. The worker passes WaitTimeSeconds explicitly, so
  # this only covers callers that do not. Zero here would mean a receive returns empty
  # immediately, billing a request per task every few milliseconds on an idle fleet.
  receive_wait_time_seconds = 20

  # The failure boundary. maxReceiveCount counts *receives*, not failures, so a worker that
  # crashes after receiving but before POSTing still burns one of the four.
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

  # Fourteen days is the SQS maximum. A poison message is evidence, and evidence that expires
  # over a long weekend is not evidence. The main queue does not need this because anything
  # that fails there is still being retried.
  message_retention_seconds = var.dlq_message_retention_seconds

  tags = {
    Name = "${var.project_name}-deliveries-dlq"
  }
}

# Without this, any queue in the account may nominate this DLQ as its redrive target. The
# permission is not implied by the redrive_policy above, which only points one way.
resource "aws_sqs_queue_redrive_allow_policy" "dlq" {
  queue_url = aws_sqs_queue.dlq.id

  redrive_allow_policy = jsonencode({
    redrivePermission = "byQueue"
    sourceQueueArns   = [aws_sqs_queue.deliveries.arn]
  })
}
