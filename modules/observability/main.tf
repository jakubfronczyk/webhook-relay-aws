# A spend ceiling for the whole account.
#
# This is a notification, not a guardrail. AWS Budgets evaluates on a delay of roughly 8 to
# 12 hours, so it reports a runaway the next morning rather than preventing one. The actual
# protection is `just down` at the end of every session.
#
# Account-wide on purpose, with no cost_filter. A filter scoped to the project tag would
# require activating that tag as a cost allocation tag in the Billing console, which is a
# manual step with a 24 hour delay, and it would then miss any untagged resource. For a
# personal account the whole-account ceiling is both simpler and safer.

resource "aws_budgets_budget" "monthly" {
  name = "${var.project_name}-monthly"

  budget_type  = "COST"
  limit_amount = var.monthly_budget_usd
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  # Alert once this much has actually been spent. Catches a slow leak.
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = var.actual_alert_threshold_percent
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = var.alert_emails
  }

  # Alert when the month is projected to exceed the ceiling. Catches a NAT gateway left
  # running on day three, before the money is gone.
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = var.alert_emails
  }
}
