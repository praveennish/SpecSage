output "public_url" {
  description = "The stable public entry point. Does not change across make down / make up."
  value       = "https://${aws_cloudfront_distribution.main.domain_name}"
}

output "cloudfront_distribution_id" {
  description = "Needed for cache invalidations and by the compute layer's origin update."
  value       = aws_cloudfront_distribution.main.id
}

output "ecr_repository_url" {
  description = "docker push target."
  value       = aws_ecr_repository.api.repository_url
}

output "artifacts_bucket" {
  description = "Corpus, pipeline output, and service snapshots. Never destroyed."
  value       = aws_s3_bucket.artifacts.id
}

output "web_bucket" {
  description = "Static assets served via CloudFront OAC."
  value       = aws_s3_bucket.web.id
}

output "compute_attached" {
  description = "False means CloudFront is serving the paused page — compute is torn down."
  value       = local.compute_up
}
