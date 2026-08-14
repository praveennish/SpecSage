# ============================================================================
#  YOUR FILE. Everything else in infra/compute/ is scaffolding.
#
#  Written by Praveen. Reviewed 2026-08-11.
#
#  `terraform validate` is your test: outputs.tf already references
#  aws_lambda_function.api and aws_lambda_function_url.api, so wrong names fail fast.
#
#  Reference: docs/runbooks/M0-compute-console.md Phase 3
# ============================================================================

locals {
  # Already written for you. Produces e.g.
  #   941500193593.dkr.ecr.us-east-1.amazonaws.com/specsage-api:7f808fd
  image_uri = format(
    "%s.dkr.ecr.%s.amazonaws.com/%s-api:%s",
    data.aws_caller_identity.current.account_id,
    var.aws_region,
    var.project,
    var.image_tag,
  )
}


# ----------------------------------------------------------------------------
# The function itself.
# ----------------------------------------------------------------------------

resource "aws_lambda_function" "api" {
  # Must match the log group name in logs.tf: "/aws/lambda/<this>".
  # Use string interpolation with var.project — see logs.tf for the same pattern.
  function_name = "${var.project}-api"

  # The execution role's ARN. Reference the resource in iam.tf, don't paste a literal.
  role = aws_iam_role.lambda_exec.arn

  # "Image", not the default "Zip". This is what tells Lambda to pull from ECR.
  package_type = "Image"

  # The local computed above.
  image_uri = local.image_uri

  # A LIST, not a string. Must match how the image was built (--platform linux/arm64),
  # or you get Runtime.InvalidEntrypoint at invoke time with no mention of architecture.
  architectures = ["arm64"]

  # Bare var references — these are numbers, so do NOT quote them.
  memory_size = var.lambda_memory_mb
  timeout     = var.lambda_timeout_seconds

  environment {
    variables = {
      # What /health reports. The deploy smoke test asserts this equals the commit that
      # triggered the deploy — that is what catches "applied fine, stale code still serving".
      GIT_SHA = var.image_tag

      SPECSAGE_ENVIRONMENT = "dev"
    }
  }

  # Both of these are dependencies Terraform CANNOT infer, because nothing in the config
  # above references either resource. Addresses only — no .arn, no .name, no quotes.
  #
  #   log group: if the function is created first, Lambda auto-creates
  #              /aws/lambda/specsage-api with NEVER-EXPIRE retention, and the
  #              aws_cloudwatch_log_group apply then fails with ResourceAlreadyExists.
  #
  #   policy attachment: a function created before its role can write logs will invoke
  #              fine and silently produce no logs until the next deploy.
  depends_on = [
    aws_cloudwatch_log_group.api,
    aws_iam_role_policy_attachment.lambda_basic,
  ]
}


# ----------------------------------------------------------------------------
# The public URL.
# ----------------------------------------------------------------------------

resource "aws_lambda_function_url" "api" {
  # Reference the function above by attribute, not by literal string.
  function_name = aws_lambda_function.api.function_name

  # "NONE" for now — see the note below before you move on.
  authorization_type = "NONE"
}

# ----------------------------------------------------------------------------
# Resource-based policy for the Function URL — BOTH statements are required.
#
# Since October 2025, a Function URL with auth type NONE needs two permissions:
# lambda:InvokeFunctionUrl AND lambda:InvokeFunction. Grant only the first and every
# request returns 403 AccessDeniedException — with a resource policy that reads as
# completely correct, an AuthType of NONE, and a perfectly healthy function.
#
# The AWS provider auto-creates only the InvokeFunctionUrl statement (the pre-Oct-2025
# shape), so the second has to be declared explicitly. Both are declared here rather
# than relying on implicit provider behaviour, so the whole policy is visible in code.
# ----------------------------------------------------------------------------

resource "aws_lambda_permission" "url_invoke_url" {
  statement_id           = "FunctionURLAllowPublicAccess"
  action                 = "lambda:InvokeFunctionUrl"
  function_name          = aws_lambda_function.api.function_name
  principal              = "*"
  function_url_auth_type = "NONE"
}

resource "aws_lambda_permission" "url_invoke_function" {
  statement_id  = "FunctionURLInvokeAllowPublicAccess"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.api.function_name
  principal     = "*"

  # P-02 Least Privilege. This condition is the difference between "anyone with the URL
  # can call the API" and "any AWS principal can invoke this function directly by ARN".
  # Without it the grant is unbounded; with it, the Function URL is the only way in.
  invoked_via_function_url = true
}

# ----------------------------------------------------------------------------
# On authorization_type = "NONE"
#
# The URL becomes publicly invokable by anyone who learns it, bypassing CloudFront.
# Harmless for /health. NOT harmless at M6, when /answer spends Bedrock money per call.
#
# The production answer is AWS_IAM + a CloudFront Origin Access Control with
# origin_access_control_origin_type = "lambda", plus an aws_lambda_permission granting
# cloudfront.amazonaws.com invoke rights scoped by SourceArn to the distribution — the
# same pattern already protecting the S3 web bucket, applied to a different origin type.
#
# Do NONE first, confirm the checkpoint is green, then tighten (runbook Phase 5).
# Changing two variables at once means you cannot tell which one broke it.
# ----------------------------------------------------------------------------
