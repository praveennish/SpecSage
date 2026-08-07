# Durable storage: the corpus, pipeline output, service snapshots, and the static web assets
# CloudFront serves.
#
# Two buckets rather than one, because they have different access models: `artifacts` is only
# ever read by compute (never public, no CloudFront), while `web` is read by CloudFront via an
# Origin Access Control. Mixing them would mean granting CloudFront read access to the corpus.

locals {
  artifacts_bucket = "${var.project}-artifacts-${var.aws_account_id}"
  web_bucket       = "${var.project}-web-${var.aws_account_id}"
}

# --------------------------------------------------------------------------- artifacts

resource "aws_s3_bucket" "artifacts" {
  bucket = local.artifacts_bucket

  # The M4 knowledge graph costs one LLM call per chunk to rebuild; the M1 corpus depends on
  # sources that rate-limit and move. Terraform must refuse to delete this.
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "artifacts" {
  bucket                  = aws_s3_bucket.artifacts.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

# Prefix-scoped retention. Snapshots churn on every `make down`, so they expire aggressively;
# raw and processed corpus data is kept indefinitely because re-acquiring it is the expensive
# part.
resource "aws_s3_bucket_lifecycle_configuration" "artifacts" {
  bucket     = aws_s3_bucket.artifacts.id
  depends_on = [aws_s3_bucket_versioning.artifacts]

  rule {
    id     = "expire-old-snapshots"
    status = "Enabled"
    filter { prefix = "snapshots/" }

    noncurrent_version_expiration {
      noncurrent_days           = 14
      newer_noncurrent_versions = 3
    }
  }

  rule {
    id     = "expire-noncurrent-corpus-versions"
    status = "Enabled"
    filter { prefix = "raw/" }

    noncurrent_version_expiration {
      noncurrent_days           = 90
      newer_noncurrent_versions = 5
    }
  }

  rule {
    id     = "abort-stalled-uploads"
    status = "Enabled"
    filter {}

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

resource "aws_s3_bucket_policy" "artifacts_tls_only" {
  bucket = aws_s3_bucket.artifacts.id
  policy = data.aws_iam_policy_document.artifacts_tls_only.json
}

data "aws_iam_policy_document" "artifacts_tls_only" {
  statement {
    sid    = "DenyNonTLSRequests"
    effect = "Deny"
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.artifacts.arn,
      "${aws_s3_bucket.artifacts.arn}/*",
    ]
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

# --------------------------------------------------------------------------- web

resource "aws_s3_bucket" "web" {
  bucket = local.web_bucket
}

resource "aws_s3_bucket_public_access_block" "web" {
  bucket = aws_s3_bucket.web.id

  # Still fully blocked. CloudFront reads via an Origin Access Control using a signed
  # service-principal request, NOT public access — so "block all public access" and "served
  # on the internet" are both true at once. This is the modern replacement for the old
  # public-bucket-as-website pattern.
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "web" {
  bucket = aws_s3_bucket.web.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "web" {
  bucket = aws_s3_bucket.web.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# The "demo paused" page CloudFront serves when compute is torn down. Managed by Terraform
# rather than uploaded by hand so the deployed page always matches what is in git.
resource "aws_s3_object" "paused_page" {
  bucket       = aws_s3_bucket.web.id
  key          = "paused.html"
  source       = "${path.module}/../../frontend/paused.html"
  etag         = filemd5("${path.module}/../../frontend/paused.html")
  content_type = "text/html; charset=utf-8"

  # Short TTL: this page changes rarely, but when it does (M10 turns it into the cost
  # circuit-breaker page) you want the change visible without an invalidation.
  cache_control = "public, max-age=60"
}
