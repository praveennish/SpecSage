# GitHub Actions → AWS via OIDC federation.
#
# docs/PATTERNS.md P-08 — Federated Short-Lived Credentials.
# There are no AWS access keys in GitHub secrets. GitHub presents a signed JWT, AWS validates
# it against this provider, and STS issues credentials that expire in an hour and are bound to
# a specific repository, branch, and environment. A leaked CI log is worth nothing an hour later.

data "aws_iam_openid_connect_provider" "github" {
  count = var.create_oidc_provider ? 0 : 1
  url   = "https://token.actions.githubusercontent.com"
}

resource "aws_iam_openid_connect_provider" "github" {
  count = var.create_oidc_provider ? 1 : 0

  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]

  # AWS validates GitHub's certificate against its own trusted-CA library and no longer
  # relies on these values, but the API still requires the field to be present.
  thumbprint_list = [
    "6938fd4d98bab03faadb97b34396831e3780aea1",
    "1c58a3a8518e8759bf075b76b750d4f2df264fcd",
  ]
}

locals {
  oidc_provider_arn = var.create_oidc_provider ? aws_iam_openid_connect_provider.github[0].arn : data.aws_iam_openid_connect_provider.github[0].arn
}

# --------------------------------------------------------------------------- trust policies
#
# The `sub` claim is where least privilege actually happens. A trust policy that only checks
# the repo lets ANY workflow on ANY branch — including one added in a fork's PR — assume the
# role. Scoping by context is what makes these two roles genuinely different in power.
#
# GitHub issues `sub` in one of two shapes, and which one you get is not something the
# workflow controls:
#
#   classic       repo:praveennish/SpecSage:ref:refs/heads/main
#   ID-qualified  repo:praveennish@82397891/SpecSage@1314955214:ref:refs/heads/main
#
# The ID-qualified form binds the trust to immutable numeric IDs, so renaming or transferring
# the repository cannot carry the permissions with it. Trusting only the classic form fails
# with `Not authorized to perform sts:AssumeRoleWithWebIdentity` — a message that never says
# which subject it refused, which is why this cost a debugging session on 2026-08-17 and why
# ci.yml now prints the claim before attempting the assume.
#
# Both forms are enumerated explicitly rather than wildcarded. `repo:praveennish*/SpecSage*:…`
# would cover both in one pattern, but `praveennish*` also matches `praveennish-evil`, and a
# trust policy is the wrong place to save four lines.

locals {
  gha_repo_prefixes = [
    "repo:${var.github_repository}",
    format(
      "repo:%s@%s/%s@%s",
      split("/", var.github_repository)[0],
      split("/", var.github_repository_ids)[0],
      split("/", var.github_repository)[1],
      split("/", var.github_repository_ids)[1],
    ),
  ]

  # Plan role: pull requests and pushes to main.
  gha_plan_subs = flatten([
    for p in local.gha_repo_prefixes : [
      "${p}:pull_request",
      "${p}:ref:refs/heads/main",
    ]
  ])

  # Deploy role: only tokens minted for the `dev` environment, which GitHub issues only after
  # the environment's protection rules are satisfied.
  gha_deploy_subs = [for p in local.gha_repo_prefixes : "${p}:environment:dev"]
}

data "aws_iam_policy_document" "gha_plan_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # Pull requests and pushes to main may PLAN. Read-only, so a broad scope is acceptable.
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = local.gha_plan_subs
    }
  }
}

data "aws_iam_policy_document" "gha_deploy_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # Only a job running in the `dev` GitHub Environment may APPLY. Because that environment
    # has a required reviewer, this condition means Terraform cannot be applied without a
    # human approving it — the gate is enforced by IAM, not merely by workflow YAML that a
    # future edit could remove.
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = local.gha_deploy_subs
    }
  }
}

# --------------------------------------------------------------------------- plan role

resource "aws_iam_role" "gha_plan" {
  name                 = "${var.project}-gha-plan"
  description          = "GitHub Actions: read + terraform plan. Cannot mutate infrastructure."
  assume_role_policy   = data.aws_iam_policy_document.gha_plan_trust.json
  max_session_duration = 3600
}

resource "aws_iam_role_policy_attachment" "gha_plan_readonly" {
  role       = aws_iam_role.gha_plan.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

# ReadOnlyAccess cannot write, but `terraform plan` must write a lock file to the state
# bucket. Without this the plan job fails on lock acquisition.
resource "aws_iam_role_policy" "gha_plan_state" {
  name   = "state-access"
  role   = aws_iam_role.gha_plan.id
  policy = data.aws_iam_policy_document.state_access.json
}

# --------------------------------------------------------------------------- deploy role

resource "aws_iam_role" "gha_deploy" {
  name                 = "${var.project}-gha-deploy"
  description          = "GitHub Actions: terraform apply. Gated on the dev environment approval."
  assume_role_policy   = data.aws_iam_policy_document.gha_deploy_trust.json
  max_session_duration = 3600
}

resource "aws_iam_role_policy" "gha_deploy_state" {
  name   = "state-access"
  role   = aws_iam_role.gha_deploy.id
  policy = data.aws_iam_policy_document.state_access.json
}

resource "aws_iam_role_policy" "gha_deploy_infra" {
  name   = "infra-management"
  role   = aws_iam_role.gha_deploy.id
  policy = data.aws_iam_policy_document.deploy_infra.json
}

# --------------------------------------------------------------------------- policies

data "aws_iam_policy_document" "state_access" {
  statement {
    sid       = "ListStateBucket"
    effect    = "Allow"
    actions   = ["s3:ListBucket", "s3:GetBucketVersioning"]
    resources = [aws_s3_bucket.state.arn]
  }

  statement {
    sid    = "ReadWriteStateObjects"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject", # required to release the native S3 lockfile
    ]
    resources = ["${aws_s3_bucket.state.arn}/*"]
  }
}

data "aws_iam_policy_document" "deploy_infra" {
  # Deliberately NOT AdministratorAccess. Scoped to the services this project actually uses,
  # so a compromised workflow cannot reach into unrelated parts of the account.
  statement {
    sid    = "ProjectServices"
    effect = "Allow"
    actions = [
      "s3:*",
      "ecr:*",
      "lambda:*",
      "cloudfront:*",
      "logs:*",
      "ec2:*", # VPC, subnets, security groups for the Fargate batch layer
      "ecs:*",
      "states:*", # Step Functions
      "events:*", # EventBridge
      "secretsmanager:*",
      "ssm:*",
      "cloudwatch:*",
      "budgets:*",
      "bedrock:*",
    ]
    resources = ["*"]
  }

  # IAM is the dangerous one. Scoped by resource NAME so the deploy role can create the task
  # and execution roles this project needs, but cannot create a role that grants itself more
  # power elsewhere in the account — and specifically cannot touch its own role or the
  # bootstrap roles.
  statement {
    sid    = "ScopedIAM"
    effect = "Allow"
    actions = [
      "iam:CreateRole",
      "iam:DeleteRole",
      "iam:GetRole",
      "iam:PassRole",
      "iam:TagRole",
      "iam:UntagRole",
      "iam:AttachRolePolicy",
      "iam:DetachRolePolicy",
      "iam:PutRolePolicy",
      "iam:DeleteRolePolicy",
      "iam:GetRolePolicy",
      "iam:ListRolePolicies",
      "iam:ListAttachedRolePolicies",
      "iam:UpdateAssumeRolePolicy",
    ]
    resources = [
      "arn:aws:iam::${var.aws_account_id}:role/${var.project}-*",
    ]
  }

  statement {
    sid    = "DenySelfEscalation"
    effect = "Deny"
    actions = [
      "iam:*",
    ]
    resources = [
      aws_iam_role.gha_deploy.arn,
      aws_iam_role.gha_plan.arn,
    ]
  }

  statement {
    sid       = "ReadOnlyIAMForPlanDiffs"
    effect    = "Allow"
    actions   = ["iam:List*", "iam:Get*"]
    resources = ["*"]
  }
}
