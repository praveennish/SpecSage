# GitHub Actions & OIDC

How CI/CD works in SpecSage, and how it talks to AWS **without a single stored credential**.

- Diagram: [`diagrams/github-actions-oidc.png`](./diagrams/github-actions-oidc.png)
  (source: [`diagrams/github-actions-oidc.dot`](./diagrams/github-actions-oidc.dot))
- Terraform: [`../infra/bootstrap/oidc.tf`](../infra/bootstrap/oidc.tf)
- Workflows: [`../.github/workflows/ci.yml`](../.github/workflows/ci.yml) ·
  [`../.github/workflows/deploy.yml`](../.github/workflows/deploy.yml)
- Decisions: [D-009](./DECISION-LOG.md#d-009) (no static keys),
  [D-018](./DECISION-LOG.md#d-018) (manual deploy) ·
  Pattern: [P-08](./PATTERNS.md#p-08--federated-short-lived-credentials)

---

## 1. What the two workflows do

| Workflow | Trigger | Jobs | AWS? |
|---|---|---|---|
| **`ci.yml`** | every PR to `main`, every push to `main`, manual | `lint` (ruff + import-linter) · `test` (pytest, no cloud) · `docker` (build only, no push) · `terraform` (fmt + validate + **plan** for `data` and `compute`, posted as a PR comment) · `bootstrap-validate` (`validate -backend=false`) | plan only, via the **read-only** role |
| **`deploy.yml`** | **manual only** (`workflow_dispatch`), inputs `action`, `confirm`, `image_tag` | `guard` (confirm == "yes") → `deploy` (build+push image → `terraform apply` compute → attach CloudFront origin → smoke test) or `teardown` (detach origin → `terraform destroy` compute → verify nothing billable remains) | apply, via the **read-write** role, gated on the `dev` environment |

**Why deploy is manual, not on-merge** ([D-018](./DECISION-LOG.md#d-018)): the `compute` layer is
destroyed between work sessions ([D-017](./DECISION-LOG.md#d-017)), so a deploy-on-merge
workflow would be a no-op most of the time — and a workflow that usually does nothing is one
whose output nobody reads.

**Why CI never touches a live endpoint:** same reason. `compute` is usually torn down, so any
check needing a running service would be red by default. Smoke tests run in `deploy.yml`,
against what was just deployed.

---

## 2. The problem OIDC solves

The naive way to let CI call AWS: create an IAM user, generate an access key, paste
`AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` into GitHub repo secrets.

Everything wrong with that:

- **Long-lived.** The key works until someone manually rotates it. A leak (a careless `echo`, a
  compromised third-party action, a misconfigured log) is exploitable indefinitely.
- **Unscoped.** An access key cannot be restricted to "only from `main`", "only for a
  reviewed deploy", "only this repo". It is the identity, everywhere, always.
- **Stored.** It sits in GitHub's database and is copied into every runner that references it.

[D-009](./DECISION-LOG.md#d-009): **there are no AWS credentials in this repository.** Not in
secrets, not in variables, not in the Terraform. Instead, GitHub proves *who it is* per run,
and AWS hands back credentials that expire in an hour.

---

## 3. OIDC in one paragraph

**OpenID Connect** is an identity layer on OAuth 2.0. An **identity provider (IdP)** issues
short-lived, cryptographically **signed JWTs** (JSON Web Tokens) that assert claims about a
principal ("this is run 12345 of workflow deploy on branch main of repo X"). A **relying
party** fetches the IdP's public keys, verifies the signature, and then trusts the claims
without ever holding a shared secret.

GitHub Actions runs an OIDC IdP at `https://token.actions.githubusercontent.com`. AWS IAM can
be told to **federate** with an external OIDC IdP: register it once, then any IAM role may
carry a **trust policy** that allows `sts:AssumeRoleWithWebIdentity` when a presented token
comes from that IdP *and* its claims match stated conditions. STS exchanges the JWT for
temporary AWS credentials.

---

## 4. The exchange, step by step

Numbers match the diagram.

0. **(deploy only)** The job targets `environment: dev`. GitHub evaluates that environment's
   protection rules; only once they pass will it mint a token whose `sub` says
   `…:environment:dev`.
1. The job declares `permissions: id-token: write`. `aws-actions/configure-aws-credentials`
   calls GitHub's token endpoint (`ACTIONS_ID_TOKEN_REQUEST_URL`) asking for a token with
   `audience=sts.amazonaws.com`.
2. GitHub **mints and signs** a JWT. Key claims:
   - `iss` = `https://token.actions.githubusercontent.com`
   - `aud` = `sts.amazonaws.com`
   - `sub` = `repo:praveennish/SpecSage:<context>` where `<context>` is one of
     `pull_request`, `ref:refs/heads/main`, `environment:dev`
   - plus `repository`, `ref`, `sha`, `run_id`, `actor`, `event_name`, …
3. The action calls **AWS STS `AssumeRoleWithWebIdentity`** with the target `RoleArn` and the
   JWT.
4. STS fetches GitHub's public keys from `/.well-known/jwks` and **verifies the signature**.
5. STS checks `aud` against the registered provider's `client_id_list` (`[sts.amazonaws.com]`).
6. STS evaluates the **role's trust policy** conditions against the token claims —
   specifically `token.actions.githubusercontent.com:aud` and
   `token.actions.githubusercontent.com:sub`.
7. If everything matches, STS **issues temporary credentials** (`AWS_ACCESS_KEY_ID`,
   `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN`) for that role, valid for at most
   `max_session_duration` = **3600 s**.
8. The job uses those credentials for `terraform plan` / `apply` and `docker push`. They
   expire within the hour — a leaked log line is worth nothing afterward.

---

## 5. Two roles, and where least privilege actually happens

Both roles are created in the **bootstrap** layer ([`oidc.tf`](../infra/bootstrap/oidc.tf)).
The power difference between them is entirely in the **`sub` condition of the trust policy** —
not in which workflow "chooses" to use them.

> A trust policy that only checks the *repo* lets **any** workflow on **any** branch — including
> one added in a fork's PR — assume the role. Scoping by `sub` context is what makes these two
> roles genuinely different in power.

### `specsage-gha-plan` — read-only

| | |
|---|---|
| Trusts `sub` = | `repo:…:pull_request` **or** `repo:…:ref:refs/heads/main` |
| Permissions | AWS-managed `ReadOnlyAccess` + a narrow inline policy: `s3:GetObject`/`PutObject`/`DeleteObject` on the state bucket (`terraform plan` must write and release the S3 lock file) |
| Cannot | mutate any infrastructure |
| Used by | `ci.yml` → `terraform` job |

### `specsage-gha-deploy` — read-write, gated

| | |
|---|---|
| Trusts `sub` = | `repo:…:environment:dev` **only** |
| Permissions | scoped infra: `s3 · ecr · lambda · cloudfront · logs · ec2 · ecs · states · events · secretsmanager · ssm · cloudwatch · budgets · bedrock` (`*` actions, but only the services this project uses) |
| IAM permissions | **scoped by resource name** to `role/specsage-*` — it can create the task/exec roles the project needs, but cannot mint a role that grants itself more power elsewhere |
| Explicit `Deny` | `iam:*` on its own ARN and the plan role's ARN — a compromised deploy job cannot rewrite its own trust policy or escalate the plan role |
| Used by | `deploy.yml` → `deploy` / `teardown` jobs |

**The gate is enforced by IAM, not YAML.** Because `specsage-gha-deploy` trusts *only*
`sub=…:environment:dev`, and GitHub issues that `sub` *only* after the `dev` environment's
protection rules are satisfied, Terraform cannot be applied without the environment gate. A
`environment: dev` line removed from the workflow YAML doesn't "skip the gate" — it makes the
job unable to authenticate at all. YAML can be edited in the same PR that abuses it; a trust
policy cannot.

> On a **private repo on the GitHub Free plan**, environments cannot have a required-reviewer
> rule, so nothing actually pauses for approval — the `confirm: "yes"` input in `deploy.yml`
> is a weaker, YAML-only substitute. Making the repo **public** activates the real reviewer
> gate with no workflow change.

---

## 6. The `sub` claim gotcha — classic vs ID-qualified

GitHub issues `sub` in one of two shapes, and the workflow does not control which:

```
classic        repo:praveennish/SpecSage:ref:refs/heads/main
ID-qualified   repo:praveennish@82397891/SpecSage@1314955214:ref:refs/heads/main
```

The ID-qualified form binds the trust to **immutable numeric IDs**, so renaming or
transferring the repository cannot carry the permissions with it. `oidc.tf` enumerates **both
forms explicitly** for every allowed context (it does *not* wildcard — `repo:praveennish*/…`
would also match `praveennish-evil`).

If a trust policy lists only the classic form and GitHub sends the ID-qualified one, STS fails
with:

```
Not authorized to perform sts:AssumeRoleWithWebIdentity
```

— and **never says which subject it refused**. That is why `ci.yml` has a `debug OIDC
subject` step that decodes and prints the token's `sub` / `aud` / `repository` / `ref` /
`environment` claims (claims are not secret; the token is) *before* attempting the assume, so
a denial is diagnosed from fact rather than inference.

To compare by hand:

```bash
aws iam get-role --role-name specsage-gha-plan \
  --query 'Role.AssumeRolePolicyDocument.Statement[0].Condition'
```

---

## 7. What lives where

| Thing | Where | Why there |
|---|---|---|
| OIDC identity provider (`aws_iam_openid_connect_provider`) | **bootstrap** layer | chicken-and-egg: CI can't create the thing it uses to authenticate |
| `specsage-gha-plan`, `specsage-gha-deploy` roles + trust policies | **bootstrap** layer | same |
| `bootstrap` is **not** planned in CI | — | it keeps *local* state (it creates the bucket every other layer stores state in), so a runner would confidently plan "recreate the state bucket + OIDC provider" on every PR. CI runs `terraform validate -backend=false` on it instead. |
| `AWS_ACCOUNT_ID`, `AWS_REGION`, `AWS_PLAN_ROLE_ARN`, `AWS_DEPLOY_ROLE_ARN` | **repository variables** (Settings → Secrets and variables → Actions → **Variables**) | not secrets — the account ID and role ARNs are not sensitive, and keeping them as visible variables aids log debugging |
| The `dev` environment | Settings → Environments | its protection rules are what gate `:environment:dev` tokens |

> **Repository vs environment variables.** The `ci.yml` `terraform` job declares no
> `environment:` (a read-only plan should not consume the deploy gate), so it reads
> **repository** variables. Variables added under Settings → Environments → dev are
> **environment** variables, visible only to jobs that declare `environment: dev`. Same UI,
> one tab apart — the `preflight — check repo variables` step in `ci.yml` exists to catch
> exactly this mix-up with a readable message before AWS returns an opaque denial.

*(Note: `RUNBOOK.md` §3.4 currently lists only `AWS_ACCOUNT_ID` and `AWS_REGION` and says the
role ARNs are "derived". The workflows as written read `vars.AWS_PLAN_ROLE_ARN` and
`vars.AWS_DEPLOY_ROLE_ARN` directly — add those two repo variables, or reconcile the RUNBOOK.)*

---

## 8. Why this is a good posture

- **No standing secret.** Nothing to leak, rotate, or find in `git log`.
- **Bound token.** Each JWT is tied to this repo + this context (`pull_request` /
  `main` / `environment:dev`) and expires in ≤ 1 h.
- **Fork PRs can't assume.** GitHub does not grant `id-token: write` to workflows from fork
  PRs by default, and even if it did, the `sub` would not match either role's trust policy.
- **Deploy needs the environment.** Read-write access is unreachable without a
  `:environment:dev` token.
- **No self-escalation.** The deploy role's IAM permissions are name-scoped to
  `role/specsage-*` and explicitly `Deny` any `iam:*` on its own and the plan role's ARN.
- **Least-privilege reads.** The plan role is `ReadOnlyAccess` plus exactly the state-bucket
  writes `terraform plan` needs for locking — nothing more.

---

## 9. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `Not authorized to perform sts:AssumeRoleWithWebIdentity` | trust policy `sub` list doesn't match the presented `sub` (often classic vs ID-qualified) | read the `debug OIDC subject` step output; compare to `aws iam get-role … Condition`; add the missing `sub` form in `oidc.tf` |
| `Credentials could not be loaded` / empty role ARN | `vars.AWS_PLAN_ROLE_ARN` / `AWS_DEPLOY_ROLE_ARN` unset, or set as an **environment** variable on a job with no `environment:` | add it as a **repository** variable |
| plan job denies on `s3:PutObject` to the state bucket | `ReadOnlyAccess` alone can't write the lock file | the `gha_plan_state` inline policy grants it — check it's attached |
| deploy job authenticates but `terraform apply` denies | action on a service not in `deploy_infra`, or IAM on a role outside `role/specsage-*` | widen `deploy_infra` deliberately (it is not `AdministratorAccess` on purpose) |
| deploy runs with no approval prompt | private repo on Free plan — no reviewer rule available | rely on `confirm: "yes"`, or make the repo public to activate the real gate |
| `id-token` request fails with 403 | job missing `permissions: id-token: write` | add it at job or workflow level |
