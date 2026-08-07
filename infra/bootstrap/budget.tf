# Cost tripwire.
#
# Not a circuit breaker — this notifies, it does not act. The acting version (SSM feature flag
# + kill switch) arrives at M10 when anonymous public traffic can trigger Bedrock spend.
# See docs/PATTERNS.md P-13.
#
# The FORECASTED threshold is the useful one: it fires on trajectory, before the money is
# actually spent, which is the difference between "you owe $40" and "you are on track to".

resource "aws_budgets_budget" "monthly" {
  name         = "${var.project}-monthly"
  budget_type  = "COST"
  limit_amount = tostring(var.monthly_budget_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  # Fires at 50% of a $10 budget — i.e. $5 against a ~$1.30/mo idle baseline. Early enough to
  # investigate while it is still pocket change.
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 50
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.budget_alert_email]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.budget_alert_email]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.budget_alert_email]
  }
}
