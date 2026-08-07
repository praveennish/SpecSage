# Terraform state bucket — the foundation every other layer depends on.
#
# No DynamoDB lock table: Terraform >= 1.10 stores the lock in S3 itself via
# `use_lockfile = true`. One fewer resource, one fewer IAM statement, ~$0.25/mo saved.
# Nearly every tutorial written before late 2024 still prescribes the DynamoDB table.
# See D-006.

resource "aws_s3_bucket" "state" {
  bucket = "${var.project}-tfstate-${var.aws_account_id}"

  # State loss means losing the mapping between config and real resources. Recoverable via
  # import, but expensive and error-prone — so this bucket is protected at two levels:
  # here (Terraform refuses to destroy it) and in AWS (versioning + public access block).
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket = aws_s3_bucket.state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Disables ACLs entirely — the bucket owner owns every object unconditionally. ACLs are a
# legacy access-control path that predates bucket policies and is a common source of
# accidental public exposure.
resource "aws_s3_bucket_ownership_controls" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

# Versioning on a state bucket accumulates a version per apply, forever. Expire old
# non-current versions so the bucket does not grow without bound, but keep enough history
# to recover from a bad apply.
resource "aws_s3_bucket_lifecycle_configuration" "state" {
  bucket     = aws_s3_bucket.state.id
  depends_on = [aws_s3_bucket_versioning.state]

  rule {
    id     = "expire-noncurrent-state-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days           = 90
      newer_noncurrent_versions = 10
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# Deny any request that is not TLS. S3 accepts plaintext HTTP by default; this closes it.
resource "aws_s3_bucket_policy" "state_tls_only" {
  bucket = aws_s3_bucket.state.id
  policy = data.aws_iam_policy_document.state_tls_only.json
}

data "aws_iam_policy_document" "state_tls_only" {
  statement {
    sid    = "DenyNonTLSRequests"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.state.arn,
      "${aws_s3_bucket.state.arn}/*",
    ]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}
