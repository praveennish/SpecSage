# M0 — Bootstrap: console walkthrough

Everything `infra/bootstrap/*.tf` creates, built by hand through the AWS and GitHub UIs.

**Read this before running `terraform apply`.** You do not have to click through it — the point
is to know what the apply is about to create, where each setting lives in the console, and
where the console default differs from what the Terraform sets.

| Resource | Terraform file | Console location |
|---|---|---|
| State bucket | `state.tf` | S3 |
| OIDC identity provider | `oidc.tf` | IAM → Identity providers |
| `specsage-gha-plan` role | `oidc.tf` | IAM → Roles |
| `specsage-gha-deploy` role | `oidc.tf` | IAM → Roles |
| Budget | `budget.tf` | Billing → Budgets |
| `dev` environment | *(GitHub, not Terraform)* | Repo → Settings → Environments |

---

## Part 0 — GitHub repository (do this first)

The repo exists at `https://github.com/praveennish/SpecSage` and is **private** — an
unauthenticated request returns 404 for private repos, which is how GitHub avoids confirming
that a private repo exists at all.

That single fact decides whether the M0 approval gate is real, so settle it before applying.

### Private vs public — this decides whether the approval gate works

> **Deployment protection rules (required reviewers, wait timers, branch policies) are only
> available on private repositories with GitHub Pro, Team, or Enterprise.** On a free plan
> they work on **public** repos only.

| Repo | Plan | Required reviewers | Consequence |
|---|---|---|---|
| **Private** | **Free** | ❌ unavailable | The `dev` environment can be created, but the protection rule cannot — deploys apply unattended. **This is your current state.** |
| Public | Free | ✅ available | Approval gate works as designed, $0 |
| Private | Pro (~$4/mo) | ✅ available | Works, costs money |

**Recommendation: make it public.** It is a portfolio project meant to be read by interviewers,
and `docs/DECISION-LOG.md` plus `docs/PATTERNS.md` are a large part of what makes it worth
reading. Public also keeps the approval gate real at zero cost.

Nothing secret is in the repo: credentials live in `~/.aws/credentials` and Secrets Manager,
`.gitignore` excludes `terraform.tfvars` and `.env.local`, and detect-secrets runs pre-commit.
The account ID is not a secret — it appears in every role ARN and is not usable without
credentials.

**To flip it:** repo → **Settings** → scroll to **Danger Zone** → **Change repository
visibility** → **Make public**.

**If you keep it private on the free plan**, the environment still does useful work — it scopes
the OIDC `sub` claim, so the IAM binding in Part 3b holds — but nothing pauses for approval.
Say so and I will add a manual `workflow_dispatch` confirmation input to `deploy.yml` as a
partial substitute. It is weaker (YAML can be edited away; an IAM trust policy cannot) but it
is better than an unattended apply.

---

## Part 1 — S3 state bucket

**Terraform:** `state.tf` · **Console:** S3 → Buckets → Create bucket

| Field | Set to | Console default | Why it differs |
|---|---|---|---|
| Bucket name | `specsage-tfstate-941500193593` | — | Account ID suffix guarantees global uniqueness |
| Region | us-east-1 | — | Matches everything else |
| **Object Ownership** | ACLs disabled (BucketOwnerEnforced) | ACLs disabled | Same — AWS fixed this default in 2023 |
| **Block Public Access** | All four ✅ | All four ✅ | Same |
| **Bucket Versioning** | **Enable** | Disabled | ⚠️ Console default is off. State without versioning means a bad apply is unrecoverable. |
| **Default encryption** | SSE-S3 (AES256) | SSE-S3 | Same |
| **Bucket Key** | Enable | Enable | Same |

Then two things the create-bucket wizard does not offer:

**Lifecycle rule** — Bucket → Management → Create lifecycle rule
- Name: `expire-noncurrent-state-versions`
- Scope: apply to all objects
- ☑ Permanently delete noncurrent versions → **90 days**, keep newest **10**
- ☑ Delete expired object delete markers / incomplete multipart uploads → **7 days**

*Why:* versioning writes a new version on every apply, forever. Without expiry the bucket
grows without bound; keeping 10 versions is more than enough to recover from a bad apply.

**TLS-only bucket policy** — Bucket → Permissions → Bucket policy → Edit

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Sid": "DenyNonTLSRequests",
    "Effect": "Deny",
    "Principal": "*",
    "Action": "s3:*",
    "Resource": [
      "arn:aws:s3:::specsage-tfstate-941500193593",
      "arn:aws:s3:::specsage-tfstate-941500193593/*"
    ],
    "Condition": { "Bool": { "aws:SecureTransport": "false" } }
  }]
}
```

*Why:* S3 accepts plaintext HTTP by default. This closes it. Console offers no checkbox for it.

> **Terraform adds one protection the console cannot:** `lifecycle { prevent_destroy = true }`
> makes `terraform destroy` refuse to delete this bucket. There is no console equivalent —
> the nearest is enabling MFA Delete, which is stricter but far more awkward to operate.

---

## Part 2 — OIDC identity provider

**Terraform:** `oidc.tf` · **Console:** IAM → Identity providers → Add provider

| Field | Value |
|---|---|
| Provider type | **OpenID Connect** |
| Provider URL | `https://token.actions.githubusercontent.com` |
| Audience | `sts.amazonaws.com` |

Click **Get thumbprint** if the console asks. AWS validates GitHub's certificate against its
own trusted-CA library and no longer relies on the thumbprint, but the API still requires the
field — which is why the Terraform hardcodes two known values rather than computing one.

> **AWS allows exactly one provider per URL per account.** If one already exists, creating a
> second fails with `EntityAlreadyExists`. That is what
> `create_oidc_provider = false` in `terraform.tfvars` is for. Yours is currently empty —
> verified with `aws iam list-open-id-connect-providers` — so leave it `true`.

**What this actually does:** it tells AWS "I trust JWTs signed by GitHub's OIDC issuer." It
grants nothing on its own. The roles below are what turn a trusted token into permissions.

---

## Part 3 — The two CI roles

**Terraform:** `oidc.tf` · **Console:** IAM → Roles → Create role → **Web identity**

This is the part worth understanding rather than clicking, because the trust policy is where
the security actually lives.

### 3a — `specsage-gha-plan` (read + plan)

1. Trusted entity: **Web identity**
2. Identity provider: `token.actions.githubusercontent.com`
3. Audience: `sts.amazonaws.com`
4. GitHub organisation / repository: your username / `SpecSage`
5. Permissions: attach **`ReadOnlyAccess`**
6. Name: `specsage-gha-plan`

Then edit the trust relationship (Role → Trust relationships → Edit) to constrain `sub`:

```json
"Condition": {
  "StringEquals": { "token.actions.githubusercontent.com:aud": "sts.amazonaws.com" },
  "StringLike":   { "token.actions.githubusercontent.com:sub": [
    "repo:praveennish/SpecSage:pull_request",
    "repo:praveennish/SpecSage:ref:refs/heads/main"
  ]}
}
```

And add an inline policy for state access — `ReadOnlyAccess` cannot write, but
`terraform plan` must write a lock file, so the plan job fails on lock acquisition without it:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    { "Effect": "Allow", "Action": ["s3:ListBucket","s3:GetBucketVersioning"],
      "Resource": "arn:aws:s3:::specsage-tfstate-941500193593" },
    { "Effect": "Allow", "Action": ["s3:GetObject","s3:PutObject","s3:DeleteObject"],
      "Resource": "arn:aws:s3:::specsage-tfstate-941500193593/*" }
  ]
}
```

### 3b — `specsage-gha-deploy` (apply)

Same creation flow, but the trust condition is one line and it is the important one:

```json
"StringEquals": {
  "token.actions.githubusercontent.com:aud": "sts.amazonaws.com",
  "token.actions.githubusercontent.com:sub": "repo:praveennish/SpecSage:environment:dev"
}
```

Permissions: the two inline policies from `oidc.tf` — `state-access` (identical to the plan
role's) and `infra-management` (scoped to the services this project uses, **not**
`AdministratorAccess`).

> **The console's Web identity wizard defaults to `sub: repo:owner/repo:*`.** That wildcard
> lets *any* workflow on *any* branch assume the role — including one added by a pull request.
> Both roles here narrow it deliberately. If you build this by hand, editing that condition is
> the single most important step on the page.

---

## Part 4 — What `environment:dev` in the `sub` claim actually means

This is the answer to "what is the dev environment and why does IAM care".

A **GitHub Environment** is a named deployment target with protection rules and scoped
secrets. When a workflow job declares one:

```yaml
jobs:
  apply:
    environment: dev          # ← this line
    permissions:
      id-token: write
```

GitHub mints an OIDC token whose `sub` claim becomes:

```
repo:praveennish/SpecSage:environment:dev
```

Without that line, the same job's token reads `repo:praveennish/SpecSage:ref:refs/heads/main`
instead — which the deploy role's trust policy does **not** match, so `AssumeRoleWithWebIdentity`
fails.

**The consequence is the point:** the approval gate is enforced by IAM, not by workflow YAML.
Someone editing `deploy.yml` to delete `environment: dev` does not bypass the gate — they make
the job unable to authenticate at all. A protection rule that lives only in YAML can be edited
away in the same PR that abuses it; this one cannot.

**The trade-off:** if the `dev` environment does not exist in GitHub, deploys fail with a
confusing `Not authorized to perform sts:AssumeRoleWithWebIdentity` rather than an obvious
"no approval configured". That error is in `docs/RUNBOOK.md` §9 for exactly this reason.

### Creating it

1. Repo → **Settings** → **Environments** → **New environment**
2. Name: `dev` → **Configure environment**
3. ☑ **Required reviewers** → add yourself → **Save protection rules**

   *(If this checkbox is greyed out, the repo is private on a free plan — see Part 0.)*

4. Optionally: **Deployment branches** → *Selected branches* → `main`

**Verify:** the environment appears under Settings → Environments with "1 reviewer" beside it.

### Repository variables

Repo → Settings → Secrets and variables → **Actions** → **Variables** tab:

| Name | Value |
|---|---|
| `AWS_ACCOUNT_ID` | `941500193593` |
| `AWS_REGION` | `us-east-1` |
| `AWS_PLAN_ROLE_ARN` | from `terraform output gha_plan_role_arn` |
| `AWS_DEPLOY_ROLE_ARN` | from `terraform output gha_deploy_role_arn` |

**Variables, not Secrets.** There are no credentials here — OIDC replaced them. Role ARNs and
account IDs are not sensitive, and keeping them visible in workflow logs helps debugging.

---

## Part 5 — Budget

**Terraform:** `budget.tf` · **Console:** Billing and Cost Management → Budgets → Create budget

1. **Use a template (simplified)** → **Monthly cost budget**
2. Name `specsage-monthly`, amount **$10**, your email
3. Create

The template gives you 85%/100% actual plus 100% forecast. The Terraform sets 50% actual,
100% actual, and 100% forecast — the 50% trigger fires at $5 against a ~$1.30/mo baseline,
early enough that investigating is cheap.

**The forecast alert is the one that matters.** Actual alerts tell you money is gone; forecast
alerts fire on trajectory.

---

## Part 6 — Applying it for real

```bash
cd infra/bootstrap
cp terraform.tfvars.example terraform.tfvars   # then edit
terraform init
terraform plan      # read it — ~14 resources, no deletions
terraform apply
```

Expected: state bucket + 6 bucket sub-resources, OIDC provider, 2 roles, 4 role policies,
1 budget. **No resource should show as being destroyed or replaced** — this is a first apply.

Then:

```bash
terraform output next_steps
```

**Cost:** ~$0.05/mo. S3 state storage is a few KB; IAM roles, the OIDC provider, and budgets
are all free.

> **Migrating bootstrap's own state:** this layer uses local state by design (it creates the
> bucket that everything else stores state in — chicken and egg). The local `terraform.tfstate`
> is gitignored. Losing it is recoverable via `terraform import`; nothing here holds data, only
> identity and permissions.
