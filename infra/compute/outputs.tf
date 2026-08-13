# These reference the resources you write in lambda.tf, so `terraform validate` will fail
# until both exist with the expected names. That is deliberate — it turns the naming contract
# into a compile-time check rather than something you discover at apply.

output "function_url" {
  description = <<-EOT
    Public URL of the function, e.g. https://abc123.lambda-url.us-east-1.on.aws/

    Fed to the data layer to attach CloudFront:
      terraform -chdir=../data apply -var="lambda_function_url=$(terraform output -raw function_url)"

    The data layer strips the scheme and trailing slash itself (see local.lambda_origin_domain
    in infra/data/cloudfront.tf) — pass it through unmodified.
  EOT
  value       = aws_lambda_function_url.api.function_url
}

output "function_name" {
  value = aws_lambda_function.api.function_name
}

output "function_arn" {
  value = aws_lambda_function.api.arn
}

output "deployed_image" {
  description = "Exact image URI running. Cross-check against /health's git_sha."
  value       = aws_lambda_function.api.image_uri
}

output "log_group" {
  value = aws_cloudwatch_log_group.api.name
}
