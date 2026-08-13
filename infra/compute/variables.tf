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

variable "image_tag" {
  description = <<-EOT
    Git SHA of the image to deploy, e.g. "7f808fd".

    Deliberately REQUIRED with no default. A `latest` default would make "which commit is
    running" unanswerable from the config, and would defeat the deploy smoke test that asserts
    /health's git_sha equals the triggering commit. One commit, one image
    (docs/PATTERNS.md P-04, Immutable Infrastructure).
  EOT
  type        = string

  validation {
    condition     = !contains(["latest", "main", ""], var.image_tag)
    error_message = "image_tag must be a specific git SHA, not a moving tag like 'latest'."
  }
}

variable "lambda_memory_mb" {
  description = <<-EOT
    Memory in MB. On Lambda this also scales CPU — 1024 MB is roughly one full vCPU, which
    roughly halves container cold start versus 512 MB. It is a latency knob as much as a
    memory knob, and it is why the console default of 128 MB cannot even boot this image.
  EOT
  type        = number
  default     = 1024

  validation {
    condition     = var.lambda_memory_mb >= 512
    error_message = "A Python container image will not start reliably below 512 MB."
  }
}

variable "lambda_timeout_seconds" {
  description = "30s suits /health. M6 synthesis will need more; raise it then, not now."
  type        = number
  default     = 30
}

variable "log_retention_days" {
  description = "7 days in dev. The default when Lambda auto-creates the group is NEVER EXPIRE."
  type        = number
  default     = 7
}
