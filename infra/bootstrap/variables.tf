variable "aws_account_id" {
  description = "12-digit AWS account ID. Enforced by the provider's allowed_account_ids."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.aws_account_id))
    error_message = "aws_account_id must be exactly 12 digits."
  }
}

variable "aws_region" {
  description = "Primary region. us-east-1 for Bedrock model availability and CloudFront/WAF."
  type        = string
  default     = "us-east-1"
}

variable "aws_profile" {
  description = "Named credentials profile. Never 'default' — that is the corporate SSO profile."
  type        = string
  default     = "specsage"
}

variable "project" {
  description = "Resource name prefix."
  type        = string
  default     = "specsage"
}

variable "github_repository" {
  description = "owner/repo that CI roles will trust via OIDC."
  type        = string
  default     = "praveennish/SpecSage"

  validation {
    condition     = can(regex("^[^/]+/[^/]+$", var.github_repository))
    error_message = "github_repository must be in owner/repo form."
  }
}

variable "github_repository_ids" {
  description = <<-EOT
    owner_id/repo_id — the NUMERIC GitHub IDs, e.g. "82397891/1314955214".

    GitHub can issue OIDC tokens with an ID-qualified subject claim:

      repo:praveennish@82397891/SpecSage@1314955214:ref:refs/heads/main
           ^^^^^^^^^^^ ^^^^^^^^ ^^^^^^^^ ^^^^^^^^^^
           login       owner id  name     repo id

    rather than the classic `repo:owner/name:context`. The IDs make the subject immune to
    renames and transfers — a repo renamed out from under a trust policy can no longer
    silently inherit its permissions, and a new repo squatting the old name cannot claim it.

    A trust policy written for the classic form does not match, and the failure is
    `Not authorized to perform sts:AssumeRoleWithWebIdentity` with no indication of which
    subject was refused. Both forms are trusted below so this works regardless of which
    GitHub issues.

    Find them with:
      curl -s https://api.github.com/repos/OWNER/REPO \
        | python3 -c 'import json,sys; d=json.load(sys.stdin); print(f"{d[\"owner\"][\"id\"]}/{d[\"id\"]}")'
  EOT
  type        = string
  default     = "82397891/1314955214"

  validation {
    condition     = can(regex("^[0-9]+/[0-9]+$", var.github_repository_ids))
    error_message = "github_repository_ids must be numeric owner_id/repo_id."
  }
}

variable "monthly_budget_usd" {
  description = <<-EOT
    Monthly cost budget in USD. A tripwire, not a ceiling — the idle estimate is ~$1.30/mo,
    so this should never fire. If it does, something is wrong and you want to know in hours.
  EOT
  type        = number
  default     = 10
}

variable "budget_alert_email" {
  description = "Where budget alerts go."
  type        = string
}

variable "create_oidc_provider" {
  description = <<-EOT
    AWS permits exactly one OIDC provider per URL per account. Set false if one already
    exists for token.actions.githubusercontent.com — check with:
      aws iam list-open-id-connect-providers --profile specsage
  EOT
  type        = bool
  default     = true
}
