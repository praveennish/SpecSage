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
      source  = "hashicorp/aws"
      version = "~> 5.80"
    }
  }

  backend "s3" {
    bucket       = "specsage-tfstate-941500193593"
    key          = "compute/terraform.tfstate" # distinct key, shared bucket
    region       = "us-east-1"
    profile      = "specsage"
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
