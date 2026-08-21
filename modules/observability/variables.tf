variable "project_name" {
  description = "Project name, used in the budget name"
  type        = string
}

variable "monthly_budget_usd" {
  description = "Monthly spend ceiling for the whole account, in USD"
  type        = number
  default     = 20
}

variable "alert_emails" {
  description = "Email addresses that receive budget notifications"
  type        = list(string)

  validation {
    condition     = length(var.alert_emails) > 0
    error_message = "At least one email address is required, otherwise the budget notifies nobody."
  }
}

variable "actual_alert_threshold_percent" {
  description = "Percentage of the budget that, once actually spent, triggers an alert"
  type        = number
  default     = 80
}
