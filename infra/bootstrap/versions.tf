# Bootstrap layer — the only layer that uses LOCAL state.
#
# Chicken-and-egg: this layer creates the S3 bucket that every other layer stores its state
# in, so it cannot itself use remote state. That is deliberate and normal. The local
# terraform.tfstate is gitignored; if you lose it, `terraform import` recovers — nothing here
# holds data, only identity and permissions.
#
# This layer is NEVER destroyed. See docs/PATTERNS.md P-06 (Bulkhead).

terraform {
  required_version = ">= 1.10" # 1.10 introduced S3 native state locking (D-006)

  # State lives in the bucket THIS LAYER CREATES. That circularity is deliberate and is the
  # standard "bootstrap the bootstrapper" pattern — it trades a one-time wrinkle for removing
  # a single point of failure.
  #
  # WHY: before this, bootstrap's state existed only on one laptop and was gitignored. Losing
  # that machine would not have broken anything running, but Terraform would have lost all
  # knowledge of the state bucket, the OIDC provider, the two CI roles, and the budget —
  # recoverable only by importing 20 resources by hand.
  #
  # THE WRINKLE: recreating this layer in a FRESH account is now two steps, because the
  # backend references a bucket that would not exist yet:
  #
  #     terraform init -backend=false && terraform apply   # creates the bucket
  #     terraform init -migrate-state                      # moves state into it
  #
  # That procedure is in docs/RUNBOOK.md §5. `prevent_destroy` on the bucket means the other
  # failure mode — destroying the bucket that holds the state describing it — is already
  # blocked.
  #
  # No `profile` here: backend blocks are evaluated before variables exist, and a hardcoded
  # profile breaks CI. Credentials come from AWS_PROFILE locally, OIDC env vars in CI.
  backend "s3" {
    bucket       = "specsage-tfstate-941500193593"
    key          = "bootstrap/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.80"
    }
  }
}

provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile

  # docs/PATTERNS.md P-05 — Fail-Fast Guard Clause.
  # Evaluated during provider configuration, so a wrong-account run fails at PLAN time,
  # before Terraform has proposed a single resource. Two AWS profiles on one laptop
  # (corporate SSO on `default`, this project on `specsage`) makes this load-bearing.
  allowed_account_ids = [var.aws_account_id]

  default_tags {
    tags = {
      Project   = "SpecSage"
      ManagedBy = "terraform"
      Layer     = "bootstrap"
    }
  }
}
