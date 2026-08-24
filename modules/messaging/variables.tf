variable "project_name" {
  description = "Project name, used as the prefix for queue names and Name tags"
  type        = string
}

variable "visibility_timeout_seconds" {
  description = "How long a received message stays hidden before SQS offers it again. Must exceed worst-case delivery time."
  type        = number
  default     = 30
}

variable "max_receive_count" {
  description = "Receives allowed before SQS moves the message to the dead-letter queue"
  type        = number
  default     = 4
}

variable "message_retention_seconds" {
  description = "How long an undelivered message survives on the delivery queue. Four days."
  type        = number
  default     = 345600
}

variable "dlq_message_retention_seconds" {
  description = "How long a poison message is kept for inspection. Fourteen days, the SQS maximum."
  type        = number
  default     = 1209600
}
