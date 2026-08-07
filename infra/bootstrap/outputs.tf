output "state_bucket" {
  description = "Terraform state bucket. Goes into every other layer's backend block."
  value       = aws_s3_bucket.state.id
}

output "backend_config" {
  description = "Paste this into infra/environments/*/backend.tf"
  value       = <<-EOT
    terraform {
      backend "s3" {
        bucket       = "${aws_s3_bucket.state.id}"
        key          = "<layer>/terraform.tfstate"
        region       = "${var.aws_region}"
        profile      = "${var.aws_profile}"
        encrypt      = true
        use_lockfile = true
      }
    }
  EOT
}

output "gha_plan_role_arn" {
  description = "Assumed by the PR workflow. Read + plan only."
  value       = aws_iam_role.gha_plan.arn
}

output "gha_deploy_role_arn" {
  description = "Assumed by the deploy workflow, gated on the dev environment approval."
  value       = aws_iam_role.gha_deploy.arn
}

output "oidc_provider_arn" {
  value = local.oidc_provider_arn
}

output "next_steps" {
  value = <<-EOT

    Bootstrap complete. Next:

      1. Add these as GitHub repository VARIABLES (not secrets — no credentials here):
           Settings -> Secrets and variables -> Actions -> Variables

           AWS_ACCOUNT_ID       = ${var.aws_account_id}
           AWS_REGION           = ${var.aws_region}
           AWS_PLAN_ROLE_ARN    = ${aws_iam_role.gha_plan.arn}
           AWS_DEPLOY_ROLE_ARN  = ${aws_iam_role.gha_deploy.arn}

      2. Create the `dev` GitHub Environment with yourself as a required reviewer.
         The deploy role's trust policy ONLY accepts tokens from that environment, so
         without it the deploy workflow cannot authenticate at all.

      3. Wait up to 24h, then activate the `Project` cost allocation tag:
           Billing -> Cost allocation tags -> User-defined -> Project -> Activate

      4. Build the `data` and `compute` layers.
  EOT
}
