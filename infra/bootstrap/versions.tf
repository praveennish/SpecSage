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
