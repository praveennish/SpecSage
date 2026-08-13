# CloudWatch log group, created explicitly.
#
# If you let Lambda create this on first invoke, it lands with retention "Never expire" and
# logs accumulate forever at $0.03/GB/month. There is no way to set the retention at creation
# time from the Lambda side — the group must already exist.
#
# The name is not a choice: Lambda writes to /aws/lambda/<function-name> and nowhere else.

resource "aws_cloudwatch_log_group" "api" {
  name              = "/aws/lambda/${var.project}-api"
  retention_in_days = var.log_retention_days
}
