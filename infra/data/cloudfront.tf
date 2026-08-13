# Public entry point. Owns the URL, terminates TLS, and survives every `make down`.
#
# Why CloudFront at all, when a Lambda Function URL is already HTTPS:
#   1. The Function URL changes identity if the function is ever recreated; CloudFront's
#      domain is stable, so demo links and MCP client configs never break (D-010).
#   2. It is the only AWS surface that terminates TLS on an AWS-owned hostname, so we get a
#      valid certificate without registering a domain (D-011).
#   3. M10 requires CloudFront + WAF anyway. Standing it up now is week-4 work done early
#      rather than throwaway scaffolding.
#   4. $0 idle — no hourly charge, and the perpetual free tier covers demo traffic.

locals {
  # The seam between persistent and disposable. Empty => compute is torn down.
  compute_up = var.lambda_function_url != ""

  # Function URLs come through as https://<id>.lambda-url.<region>.on.aws/ but a CloudFront
  # origin wants a bare hostname.
  lambda_origin_domain = local.compute_up ? replace(replace(var.lambda_function_url, "https://", ""), "/", "") : ""

  s3_origin_id     = "s3-web"
  lambda_origin_id = "lambda-api"
}

resource "aws_cloudfront_origin_access_control" "web" {
  name                              = "${var.project}-web-oac"
  description                       = "Lets CloudFront read the private web bucket"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_distribution" "main" {
  enabled             = true
  comment             = "${var.project} — public entry point"
  default_root_object = local.compute_up ? "" : "paused.html"

  # NA + EU only. The cheapest tier, and every viewer of this demo is a recruiter, an
  # interviewer, or Praveen.
  price_class = "PriceClass_100"

  # --- origins ---------------------------------------------------------------------------

  origin {
    origin_id                = local.s3_origin_id
    domain_name              = aws_s3_bucket.web.bucket_regional_domain_name
    origin_access_control_id = aws_cloudfront_origin_access_control.web.id
  }

  dynamic "origin" {
    for_each = local.compute_up ? [1] : []
    content {
      origin_id   = local.lambda_origin_id
      domain_name = local.lambda_origin_domain

      custom_origin_config {
        http_port              = 80
        https_port             = 443
        origin_protocol_policy = "https-only"
        origin_ssl_protocols   = ["TLSv1.2"]

        # Lambda cold start on a container image can take a few seconds. The default 30s
        # read timeout is enough for /health but not for a synthesis call at M6, so this is
        # set near the ceiling now to avoid a confusing 504 later.
        origin_read_timeout      = 60
        origin_keepalive_timeout = 60
      }
    }
  }

  # --- behaviours ------------------------------------------------------------------------

  default_cache_behavior {
    target_origin_id       = local.compute_up ? local.lambda_origin_id : local.s3_origin_id
    viewer_protocol_policy = "redirect-to-https"
    compress               = true

    allowed_methods = local.compute_up ? ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"] : ["GET", "HEAD"]
    cached_methods  = ["GET", "HEAD"]

    # CachingDisabled when the API is live: every response is dynamic, and caching /answer
    # would serve one user's answer to another. The S3 fallback uses CachingOptimized.
    cache_policy_id = local.compute_up ? data.aws_cloudfront_cache_policy.disabled.id : data.aws_cloudfront_cache_policy.optimized.id

    # AllViewerExceptHostHeader: forwards everything to Lambda except Host. A Function URL
    # validates Host against its own domain and returns 403 if CloudFront forwards the
    # viewer's Host instead — this is the single most common Function-URL-behind-CloudFront
    # failure, and it presents as a flat 403 with no useful message.
    origin_request_policy_id = local.compute_up ? data.aws_cloudfront_origin_request_policy.all_viewer_except_host.id : null
  }

  # The paused page must always be reachable from the S3 origin, including while the API is
  # up — the error responses below reference it by path.
  ordered_cache_behavior {
    path_pattern           = "/paused.html"
    target_origin_id       = local.s3_origin_id
    viewer_protocol_policy = "redirect-to-https"
    compress               = true
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    cache_policy_id        = data.aws_cloudfront_cache_policy.optimized.id
  }

  # --- graceful degradation ---------------------------------------------------------------
  #
  # The mapped error codes differ by state, and getting this wrong is subtle:
  #
  #   compute DOWN -> 403/404. Every path resolves to the S3 origin, which has only
  #                   paused.html, so /health returns S3's raw 404 XML without this. These are
  #                   origin errors from a bucket that legitimately has nothing else in it.
  #
  #   compute UP   -> 502/503/504 ONLY. These mean CloudFront could not reach Lambda. 403 and
  #                   404 are deliberately NOT mapped here: those are the API's own responses,
  #                   and rewriting them to a 200 paused page would mask real "not found" and
  #                   "forbidden" results from every client, including the M8 MCP tools.
  #
  # This is also the mechanism M10's cost circuit breaker reuses — build it once (P-13).

  dynamic "custom_error_response" {
    for_each = local.compute_up ? [502, 503, 504] : [403, 404]
    content {
      error_code            = custom_error_response.value
      response_code         = 200
      response_page_path    = "/paused.html"
      error_caching_min_ttl = 10
    }
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    # The free AWS-managed certificate on *.cloudfront.net. This is the entire reason no
    # domain was registered — ACM will not issue for an ALB's or Function URL's own hostname,
    # but CloudFront terminates TLS on a domain AWS owns. See D-010.
    cloudfront_default_certificate = true

    # minimum_protocol_version is DELIBERATELY OMITTED.
    #
    # With the default certificate, CloudFront ignores it and pins the reported value to
    # "TLSv1". Setting "TLSv1.2_2021" produced a PERPETUAL DIFF: every plan showed
    # `~ minimum_protocol_version = "TLSv1" -> "TLSv1.2_2021"` and every apply silently
    # failed to change it. That is worse than it sounds — a plan that never comes back clean
    # cannot be used as a drift check, and it trains you to skim plan output.
    #
    # The security posture is fine regardless. Verified empirically against the live
    # distribution on 2026-08-08:
    #     TLS 1.0 -> connection refused
    #     TLS 1.2 -> 200
    #     TLS 1.3 -> 200
    # AWS has deprecated TLS 1.0/1.1 on *.cloudfront.net, so the reported "TLSv1" is a
    # nominal value, not what is negotiated.
    #
    # Enforcing an explicit minimum requires a custom domain + ACM certificate. That is a
    # real, documented cost of D-010/D-011 (no domain registered) and is revisited at M10.
  }
}

# --- bucket policy: CloudFront-only read -------------------------------------------------

resource "aws_s3_bucket_policy" "web_oac_read" {
  bucket = aws_s3_bucket.web.id
  policy = data.aws_iam_policy_document.web_oac_read.json
}

data "aws_iam_policy_document" "web_oac_read" {
  statement {
    sid    = "AllowCloudFrontServicePrincipalReadOnly"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }

    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.web.arn}/*"]

    # Scopes the grant to THIS distribution. Without it, any CloudFront distribution in any
    # AWS account could read the bucket — the service principal is shared across all of them.
    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.main.arn]
    }
  }

  statement {
    sid    = "DenyNonTLSRequests"
    effect = "Deny"
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.web.arn, "${aws_s3_bucket.web.arn}/*"]
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

# --- AWS managed policies ------------------------------------------------------------------

data "aws_cloudfront_cache_policy" "disabled" {
  name = "Managed-CachingDisabled"
}

data "aws_cloudfront_cache_policy" "optimized" {
  name = "Managed-CachingOptimized"
}

data "aws_cloudfront_origin_request_policy" "all_viewer_except_host" {
  name = "Managed-AllViewerExceptHostHeader"
}
