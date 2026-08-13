# Lambda execution role.
#
# P-02 Least Privilege, applied as "add when needed" rather than "grant now in case".
# For M0 the function talks to CloudWatch Logs and nothing else. Bedrock, S3, and Secrets
# Manager permissions arrive at M3/M4 when a code path actually calls them — at which point
# the diff shows exactly which milestone widened the blast radius, and why.

data "aws_iam_policy_document" "lambda_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda_exec" {
  name               = "${var.project}-lambda-exec"
  description        = "Execution role for the SpecSage API function. Logs only at M0."
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

resource "aws_iam_role_policy_attachment" "lambda_basic" {
  role       = aws_iam_role.lambda_exec.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}
