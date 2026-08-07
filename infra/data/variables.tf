variable "aws_account_id" {
  description = "12-digit AWS account ID. Enforced by the provider's allowed_account_ids."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.aws_account_id))
    error_message = "aws_account_id must be exactly 12 digits."
  }
}

variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "aws_profile" {
  type    = string
  default = "specsage"
}

variable "project" {
  type    = string
  default = "specsage"
}

variable "log_retention_days" {
  description = "CloudWatch retention. 7 days in dev keeps the log bill at pennies."
  type        = number
  default     = 7
}

variable "ecr_image_count" {
  description = "Untagged/old images to retain before the lifecycle policy expires them."
  type        = number
  default     = 10
}

variable "lambda_function_url" {
  description = <<-EOT
    The compute layer's Lambda Function URL, e.g. https://abc123.lambda-url.us-east-1.on.aws/

    Empty by default. This is the seam between the persistent and disposable layers: when
    empty, CloudFront serves the static "paused" page for every request; when set, it routes
    to Lambda and falls back to the paused page on origin errors.

    `make up` applies the compute layer, reads its Function URL, then re-applies this layer
    with the value set. `make down` re-applies with it cleared. That is why CloudFront lives
    here (it costs nothing idle and is slow to destroy) while Lambda lives in `compute`.
  EOT
  type        = string
  default     = ""
}
