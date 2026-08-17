# Compute layer — DESTROYED between work sessions.
#
# Everything here is disposable by design. `make down` runs `terraform destroy` against this
# layer and nothing else; if a resource in here survives that, it is a bug (see the review
# criteria in docs/runbooks/M0-compute-console.md).
#
# The corollary: nothing durable may live here. No buckets, no registries, no CloudFront.
# Those belong in `data`. docs/PATTERNS.md P-06 (Bulkhead).

terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source = "hashicorp/aws"
      # 6.x required for aws_lambda_permission.invoked_via_function_url.
      #
      # Since October 2025 a Function URL with auth NONE needs TWO resource-policy statements:
      # lambda:InvokeFunctionUrl AND lambda:InvokeFunction conditioned on
      # lambda:InvokedViaFunctionUrl. Provider 5.x can only express the first, so a URL built
      # with it returns 403 with a policy that looks correct. Expressing the condition needs
      # 6.x; without it the only alternative is granting InvokeFunction to "*" unconditionally,
      # which would let any principal invoke the function directly, bypassing the URL.
      version = "~> 6.0"
    }
  }

  backend "s3" {
    bucket = "specsage-tfstate-941500193593"
    key    = "compute/terraform.tfstate" # distinct key, shared bucket
    region = "us-east-1"
    # NOTE: no `profile` here.
    #
    # Backend blocks are evaluated BEFORE variables exist, so `profile = var.aws_profile`
    # is impossible and a hardcoded "specsage" breaks CI — a GitHub runner has no
    # ~/.aws/credentials, and Terraform fails with `failed to get shared config profile`
    # before it reaches the provider at all.
    #
    # Credential resolution is left to the environment instead:
    #   local  -> AWS_PROFILE=specsage (exported by the Makefile, set in RUNBOOK §2.3)
    #   CI     -> AWS_ACCESS_KEY_ID/SECRET/SESSION_TOKEN injected by the OIDC action
    #
    # The wrong-account guard still holds: allowed_account_ids on the provider fails at plan
    # time, and a mismatched identity cannot read this state bucket in the first place.
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile

  allowed_account_ids = [var.aws_account_id] # P-05 Fail-Fast Guard Clause

  default_tags {
    tags = {
      Project   = "SpecSage"
      ManagedBy = "terraform"
      Layer     = "compute"
    }
  }
}

# Used to build the ECR image URI without hardcoding the registry host.
data "aws_caller_identity" "current" {}
