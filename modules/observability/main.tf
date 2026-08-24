# A spend ceiling for the whole account. Budgets evaluates on an 8 to 12 hour delay, so this
# is a notification and `just down` is the guardrail.
#
# No cost_filter: scoping to the project tag needs that tag activated for cost allocation, a
# manual step with a 24 hour delay, and would miss untagged resources.

resource "aws_budgets_budget" "monthly" {
  name = "${var.project_name}-monthly"

  budget_type  = "COST"
  limit_amount = var.monthly_budget_usd
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  # Alerts on money already spent.
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = var.actual_alert_threshold_percent
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = var.alert_emails
  }

  # Alerts on the projected month total. Needs about five weeks of account history before
  # AWS will produce a forecast at all.
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = var.alert_emails
  }
}
