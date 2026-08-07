# Data layer — NEVER destroyed.
#
# Holds everything whose loss is expensive or irreversible: the corpus, pipeline output,
# service snapshots, container images, and the CloudFront distribution that owns the public
# URL. `make down` does not touch this layer; only `compute` is disposable.
#
# docs/PATTERNS.md P-06 (Bulkhead) — separate state means the destroy you run most often is
# physically incapable of reaching the data you can least afford to lose.

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
    key          = "data/terraform.tfstate"
    region       = "us-east-1"
    profile      = "specsage"
    encrypt      = true
    use_lockfile = true # Terraform >= 1.10: lock lives in S3, no DynamoDB table (D-006)
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
      Layer     = "data"
    }
  }
}
