# SpecSage — Runbook

Setup, operation, deployment, rollback, and troubleshooting. Written to be followed
step by step without prior context.

**Status:** M0 in progress.
§0–§4 are actionable now. §5–§8 fill in as the Terraform layers land — each is marked
`[PENDING M0]` with what is already known.

Reasoning behind any decision referenced here lives in [DECISION-LOG.md](./DECISION-LOG.md).

---

## Contents

| § | Section | When |
|---|---|---|
| 0 | [Before you start](#0-before-you-start) | Once |
| 1 | [AWS account setup](#1-aws-account-setup) | Once, ~35 min |
| 2 | [Local development environment](#2-local-development-environment) | Once, ~5 min |
| 3 | [GitHub setup](#3-github-setup) | Once, ~10 min |
| 4 | [Third-party accounts](#4-third-party-accounts) | Deferred per milestone |
| 5 | [Bootstrap layer](#5-bootstrap-layer) | Once, by hand |
| 6 | [Daily operation](#6-daily-operation) | Every session |
| 7 | [Deploy and rollback](#7-deploy-and-rollback) | Per release |
| 8 | [Cost incident response](#8-cost-incident-response) | When it hurts |
| 9 | [Troubleshooting](#9-troubleshooting) | When it breaks |

---

## 0. Before you start

### What you need

| Thing | Notes |
|---|---|
| An AWS account you control alone | Use your **existing personal account**. See §0.1. |
| A phone or hardware key for MFA | Authenticator app is fine |
| `git`, `docker`, `terraform`, `uv`, `aws` CLI | Verify with §0.2 |
| ~35 minutes | Plus queue time on Bedrock model access, which is out of your hands |

### 0.1 Which account?

**Use the personal AWS account you already have.** A fresh account buys clean billing
isolation and possibly signup credits; it costs an hour of setup, a new Bedrock model-access
request, and fresh service quotas.

Create a new account **only** if one of these is true:

- Someone else has console or programmatic access to the existing account
- It holds production workloads you cannot risk disturbing
- It is tied to a business entity you would rather keep separate from a portfolio project

If you do create a new one, every step in §1 applies unchanged — just add "create the account
and add a payment method" at the front.

**Do not use a corporate account.** Full reasoning in
[D-014](./DECISION-LOG.md#d-014--aws-account-personal-end-to-end); the short version is data
confidentiality, ownership of the artifact, and a GitHub OIDC trust path into an employer's
account.

### 0.2 Verify your toolchain

```bash
git --version          # any recent version
docker --version       # 24+ (needed from step 2.4 onward)
terraform --version    # 1.10+ — 1.10 introduced S3 native state locking (D-006)
uv --version           # 0.5+
aws --version          # v2
```

Missing anything:

```bash
brew install git terraform awscli
brew install --cask docker
curl -LsSf https://astral.sh/uv/install.sh | sh
```

Terraform below 1.10 will fail on `use_lockfile = true` — upgrade rather than adding a
DynamoDB lock table.

---

## 1. AWS account setup

**Time:** ~35 minutes of your attention, plus queue time on step 1.5.
**Do step 1.5 first if you want to parallelise** — it is the only step that can wait on AWS.

### 1.1 — Confirm the account and record its ID

1. Sign in to the AWS console with the account you intend to use
2. Click your account name (top right) → the 12-digit **Account ID** is shown there
3. Record it — you will need it in steps 1.4, 2.3, and §5

Confirm you are the only person with access:

- **IAM → Users** — anyone you don't recognise means this is not a solo account. Stop and
  re-read §0.1.
- **IAM → Identity providers** and **IAM → Roles** — filter for roles with an external trust
  policy. An unexpected cross-account trust means the same thing.

> **Checkpoint:** you have a 12-digit account ID and no unexpected principals.

### 1.2 — MFA on the root user

Do this before anything else. The root user can do things no policy can stop.

1. Console → your account name → **Security credentials**
2. **Multi-factor authentication (MFA)** → **Assign MFA device**
3. Name it something you'll recognise (`praveen-phone`), choose **Authenticator app**
4. Scan the QR code, enter two consecutive codes
5. Sign out

**Then stop using root.** From here on, everything runs as the IAM user from step 1.3. Root is
for billing changes, account closure, and nothing else.

> **Checkpoint:** signing in as root now prompts for an MFA code.

### 1.3 — Create the admin IAM user

1. Console → **IAM** → **Users** → **Create user**
2. User name: `specsage-admin`
3. Leave "Provide user access to the AWS Management Console" **unchecked** — this user is for
   CLI and Terraform only. Fewer credentials, fewer things to leak.
4. **Next** → **Attach policies directly** → tick `AdministratorAccess`
5. **Next** → **Create user**

Then add MFA to it as well:

6. Click into `specsage-admin` → **Security credentials** tab → **Assign MFA device**
7. Same flow as step 1.2

> **Why an IAM user rather than IAM Identity Center?** For a single-person account, Identity
> Center adds an SSO portal, a permission-set model, and short-lived credentials that need
> refreshing before every Terraform run. That last part is exactly the friction that made the
> corporate account unworkable ([D-014](./DECISION-LOG.md#d-014--aws-account-personal-end-to-end)).
> A long-lived key on an MFA-protected user, scoped to one account, is the right trade here.
> The console will nudge you toward Identity Center — decline it.

### 1.4 — Generate an access key

1. Still in `specsage-admin` → **Security credentials** tab
2. Scroll to **Access keys** → **Create access key**
3. AWS shows "Alternatives recommended" — choose **Command Line Interface (CLI)**
4. Tick the confirmation box → **Next**
5. Description tag: `specsage-local-terraform`
6. **Create access key**
7. **Leave this page open.** The secret is shown exactly once.

### 1.5 — Configure the `[specsage]` credentials profile

Open `~/.aws/credentials` in an editor and **append** this block. Do not touch any existing
`[default]` section — your corporate SSO credentials live there and stay there
([D-016](./DECISION-LOG.md#d-016--credential-isolation-via-a-named-specsage-profile)).

```ini
[specsage]
aws_access_key_id = AKIAxxxxxxxxxxxxxxxx
aws_secret_access_key = xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
region = us-east-1
```

> **Paste the values raw.** Three formatting mistakes break this file, and all three produce
> misleading errors:
>
> | Mistake | Looks like | Error you get |
> |---|---|---|
> | `export AWS_ACCESS_KEY_ID = …` | shell syntax in an INI file | `Unable to locate credentials` — as if the file were empty |
> | `aws_access_key_id = "AKIA…"` | quoted value | `InvalidClientTokenId` — as if the key were revoked |
> | Missing `[specsage]` header | keys under `[default]` | silently overwrites your corporate profile |
>
> The second one is the nastiest: the parser reads `"` as the first character of the key and
> sends a malformed credential to STS, which rejects it with an error that reads like
> expiry. If you hit either of the first two, the previous file is backed up at
> `~/.aws/credentials.bak.*`.

Verify:

```bash
AWS_PROFILE=specsage aws sts get-caller-identity
```

Expected:

```json
{
    "UserId": "AIDA...",
    "Account": "123456789012",
    "Arn": "arn:aws:iam::123456789012:user/specsage-admin"
}
```

Check three things: the ARN ends in `user/specsage-admin`, the `Account` matches step 1.1, and
it is **not** an `assumed-role/AWSReservedSSO_…` ARN (that would mean you're still on the
corporate profile).

Now delete the access key from your clipboard and close the AWS console tab.

> **Checkpoint:** `AWS_PROFILE=specsage aws sts get-caller-identity` returns your personal
> account ID and an IAM user ARN.

### 1.6 — Request Bedrock model access

**Do this as early as possible.** M3 is the first consumer, but approval is not always instant
and there is no way to hurry it.

1. Console → **Amazon Bedrock** → confirm the region selector reads **US East (N. Virginia)
   / us-east-1**
2. Left nav, near the bottom → **Model access**
3. **Modify model access** (or **Enable specific models** on a fresh account)
4. Select:
   - `Anthropic — Claude Haiku 4.5`
   - `Anthropic — Claude Sonnet 5`
   - `Amazon — Titan Text Embeddings V2`
   - *(optional)* `Anthropic — Claude Opus 5` — not used by default, see
     [D-023](./DECISION-LOG.md#d-023--per-stage-model-right-sizing)
5. **Next** → if a use-case form appears, fill it in honestly: personal portfolio project,
   retrieval-augmented Q&A over public technical documentation, no end users
6. **Submit**

Status shows **Access granted** (usually within minutes) or **In progress**. Anthropic models
occasionally queue for longer.

Verify from the CLI once granted:

```bash
AWS_PROFILE=specsage aws bedrock list-foundation-models --region us-east-1 \
  --query "modelSummaries[?contains(modelId,'claude-sonnet-5') || contains(modelId,'claude-haiku-4-5') || contains(modelId,'titan-embed-text-v2')].modelId" \
  --output text | tr '\t' '\n'
```

Expected — these exact IDs are what the code will use
([D-028](./DECISION-LOG.md#d-028--bedrock-access-via-anthropicbedrockmantle-model-ids-verified)):

```
anthropic.claude-haiku-4-5-20251001-v1:0
anthropic.claude-sonnet-5
amazon.titan-embed-text-v2:0
```

Note the inconsistency: the 5-family IDs are bare, Haiku 4.5 still carries a dated suffix.
That is why they are pinned in config rather than constructed at runtime.

#### Prove it by invoking — listing is not an access check

`list-foundation-models` reports what exists in the region, **not what you are entitled to
call.** On a real account it returned all four IDs while only two were invokable. The only
reliable test is an actual invocation:

```bash
make check-bedrock
```

This makes one tiny call per model (16-token cap; a fraction of a cent for all of them) and
reports, per model, whether access is granted and **which exact ID form works**.

Expected on a fully-provisioned account:

```
us.anthropic.claude-haiku-4-5-20251001-v1:0   ✓ invoked successfully
us.anthropic.claude-sonnet-5                   ✓ invoked successfully
amazon.titan-embed-text-v2:0                   ✓ invoked successfully — 1024 dimensions
```

> **Claude models need the `us.` inference-profile prefix; Titan does not.** The bare
> `anthropic.claude-…` ID is rejected for on-demand throughput with
> `Invocation of model ID … with on-demand throughput isn't supported`. The script detects
> this and retries with the `us.` prefix automatically, then prints the working ID — that is
> the value to pin in config. The prefix rule is per-model-family, which is why the IDs are
> discovered rather than derived.

#### Reading the errors

| Error | Means | Fix |
|---|---|---|
| `AccessDeniedException: <model> is not available for this account` | Model access not granted. **Not** an IAM problem — access is account-level, and `AdministratorAccess` already grants `bedrock:InvokeModel`. | Request it in Model access. If the console already shows *Access granted*, see below. |
| `ValidationException: … on-demand throughput isn't supported` | Right access, wrong ID form | Use the `us.`-prefixed inference profile ID |
| `AccessDeniedException: User … is not authorized to perform bedrock:InvokeModel` | Genuine IAM problem — different wording, note the `User …` prefix | Check the principal's policy |
| `ThrottlingException` | Access works; quota is tight | Retry; check per-model quotas |

**If the console shows *Access granted* but invocation still returns "not available for this
account":** that is a model-enablement gap rather than an approval you're waiting on. Some
models require an account-level entitlement beyond the self-serve request. Confirm the
inference profile exists and is active —

```bash
AWS_PROFILE=specsage aws bedrock list-inference-profiles --region us-east-1 \
  --query "inferenceProfileSummaries[?contains(inferenceProfileId,'sonnet-5')].[inferenceProfileId,status]" \
  --output text
```

— and if it is `ACTIVE` while invocation is still denied, raise a support case (Service:
Bedrock, Category: model access) or use the AWS Sales contact link in the error message.

**This does not block M0–M4.** Haiku covers M4 graph extraction and M7's judge; Titan covers
M3 embeddings. Only M6 synthesis and M9 distillation need Sonnet 5, which is two weeks out.

> **Checkpoint:** `make check-bedrock` exits 0.

### 1.7 — Set up a budget alarm

Do this now, before any resource exists. It is the only cost control that works while you're
asleep.

1. Console → **Billing and Cost Management** → **Budgets** → **Create budget**
2. Choose **Use a template (simplified)** → **Monthly cost budget**
3. Budget name: `specsage-monthly`
4. Amount: **$10** — a deliberate tripwire, roughly 10× the ~$1/mo idle estimate. It should
   never fire; if it does, something is wrong and you want to know within hours.
5. Email recipient: your address
6. **Create budget**

AWS alerts at 85%, 100%, and 100% *forecast* by default. The forecast alert is the useful one —
it fires on trajectory, before the money is spent.

> **Checkpoint:** `specsage-monthly` appears under Budgets with a $10 limit.

### 1.8 — Activate the cost allocation tag *(after the first apply, not before)*

Terraform stamps `Project = SpecSage` on every resource via provider default tags. But a
user-defined cost allocation tag **cannot be activated until AWS has observed it on a real
resource** — the key does not appear in the Billing console before then, and it can take up to
24 hours to show up after the first tagged resource is created.

So the sequence is:

1. *(Now)* Nothing to do. The tag is already in the Terraform provider config.
2. *(After §5 bootstrap applies)* Wait up to 24h
3. Console → **Billing and Cost Management** → **Cost allocation tags**
4. **User-defined cost allocation tags** tab → find `Project` → select it → **Activate**

> **Activation is not retroactive.** Cost data recorded before you activate the key cannot be
> filtered by it afterwards. In practice this costs you the first day or so of M0 spend —
> pennies — but it is the reason to activate as soon as the key appears rather than at M12.

> **Checkpoint (deferred):** Cost Explorer can group by `Project` and shows a `SpecSage` value.

### 1.9 — Not required

Explicitly listed so their absence doesn't read as an oversight:

| Skipped | Why |
|---|---|
| Domain registration | CloudFront supplies free valid TLS ([D-010](./DECISION-LOG.md#d-010--https-via-cloudfronts-default-cloudfrontnet-certificate)) |
| EC2 G-instance spot quota request | Training runs on Modal/Kaggle ([D-022](./DECISION-LOG.md#d-022--fine-tuning-compute-modal--kaggle-free-tiers)). This is the only skipped item that had a multi-day lead time. |
| An IAM user for CI | GitHub Actions uses OIDC ([D-009](./DECISION-LOG.md#d-009--cicd-auth-github-oidc-no-long-lived-aws-access-keys)) |
| NAT Gateway / VPC endpoints | No private subnets in dev ([D-007](./DECISION-LOG.md#d-007--no-nat-gateway-workloads-in-public-subnets-with-sg-restricted-ingress)) |
| DynamoDB state lock table | Terraform 1.10+ locks in S3 ([D-006](./DECISION-LOG.md#d-006--terraform-state-s3-backend-with-native-lockfile)) |

---

## 2. Local development environment

### 2.1 — Clone and install

```bash
git clone https://github.com/praveennish/SpecSage.git
cd SpecSage
make install
```

`make install` runs `uv sync --all-groups`. uv downloads and pins **Python 3.12** regardless of
your system Python — no pyenv, no virtualenv activation.

### 2.2 — Verify the toolchain works

```bash
make lint    # ruff check + format check + import boundaries
make test    # unit tests only — no network, no cloud
```

Expected:

```
All checks passed!
retrieval must not depend on any agent framework KEPT
Contracts: 1 kept, 0 broken.
31 passed, 2 deselected
```

The import-linter contract is not decoration. It fails CI if `retrieval` ever imports an agent
framework, which is what makes the "swappable orchestration" claim in
[ARCHITECTURE.md](./ARCHITECTURE.md) true rather than aspirational.

### 2.3 — Configure the account guard

Every AWS-touching Make target refuses to run unless credentials resolve to the expected
account ([D-015](./DECISION-LOG.md#d-015--allowed_account_ids-provider-guardrail)).

```bash
cp .env.local.example .env.local   # if present; otherwise create it
```

`.env.local` (gitignored):

```bash
SPECSAGE_ACCOUNT_ID=123456789012   # from step 1.1
AWS_PROFILE=specsage
```

Load it into your shell:

```bash
set -a && source .env.local && set +a
make check-aws
```

Expected:

```
account 123456789012 via profile specsage — ok
```

Test that the guard actually works — a guard you haven't seen fire is a guard you don't know
you have:

```bash
SPECSAGE_ACCOUNT_ID=000000000000 make check-aws
# WRONG ACCOUNT: profile 'specsage' resolves to 123456789012, expected 000000000000
# make: *** [check-aws] Error 1
```

### 2.4 — Run it

```bash
make run-local
```

In another terminal:

```bash
curl -s localhost:8000/health | python3 -m json.tool
```

```json
{
    "status": "ok",
    "service": "specsage",
    "version": "0.1.0",
    "git_sha": "a1b2c3d",
    "environment": "local"
}
```

`git_sha` reads `"unknown"` if the repo has no commits yet. That is correct behaviour, not a
bug — a health endpoint that 500s because it cannot identify itself is worse than one that
admits it doesn't know. Covered by
`test_health_degrades_gracefully_without_git_sha`.

### 2.5 — Build the container

```bash
make docker-build
docker run --rm -p 8000:8000 specsage:latest
curl -s localhost:8000/health
```

The image runs **identically** under `docker run` and under Lambda — the Lambda Web Adapter
sits in front and speaks HTTP to the same uvicorn process. No handler shim, no
framework-specific deployment code, and local behaviour cannot silently diverge from deployed
([D-019](./DECISION-LOG.md#d-019--requestresponse-api-on-lambda-not-an-always-on-ecs-service)).

### 2.6 — Install pre-commit hooks

```bash
uv run pre-commit install
uv run detect-secrets scan > .secrets.baseline   # first run only
uv run pre-commit run --all-files
```

Hooks: ruff, ruff-format, `terraform fmt`, `terraform validate`, private-key detection, and
detect-secrets. The last two are the ones that matter — `.gitignore` covers the credential
files you expect, detect-secrets covers the ones you don't.

---

## 3. GitHub setup

### 3.1 — Push the initial commit

```bash
git add .
git commit -m "M0: scaffolding, docs, and health endpoint"
git branch -M main
git push -u origin main
```

### 3.2 — Branch protection

Repo → **Settings** → **Rules** → **Rulesets** → **New branch ruleset**:

- Target: `main`
- ☑ Require a pull request before merging
- ☑ Require status checks to pass → add `lint`, `test`, `terraform-plan` (available after the
  first CI run)
- ☑ Block force pushes

### 3.3 — Deployment environment gate

Repo → **Settings** → **Environments** → **New environment** → name it `dev`:

- ☑ **Required reviewers** → add yourself

This is what makes the deploy workflow stop and wait for a human. Without it,
`workflow_dispatch` applies Terraform unattended.

### 3.4 — Repository variables

Repo → **Settings** → **Secrets and variables** → **Actions** → **Variables** tab:

| Name | Value |
|---|---|
| `AWS_ACCOUNT_ID` | your 12-digit account ID |
| `AWS_REGION` | `us-east-1` |

**No secrets.** There are no AWS credentials in GitHub — the workflow assumes an IAM role via
OIDC, and the role ARNs are derived from `AWS_ACCOUNT_ID`. The account ID is not sensitive;
treating it as a variable rather than a secret keeps it visible in logs where it aids
debugging.

---

## 4. Third-party accounts

Deferred until the milestone that needs them. Credentials go into AWS Secrets Manager, never
into git, never into `.env.local`.

| Service | Needed by | Tier | What to create |
|---|---|---|---|
| Qdrant Cloud | M3 | Free — 1 GB, no card | A free cluster in a region near `us-east-1`; keep the URL + API key |
| Neo4j AuraDB | M4 | Free | A free instance; **save the generated password immediately** — it is shown once |
| Modal | M9 | Free monthly credits | Account + `modal token new` |
| HuggingFace | M9 | Free | Account + a write token, for publishing the adapter |

> **AuraDB free instances auto-pause after a few days idle and are deleted after ~30 days
> idle.** With this project's stop-start schedule you *will* hit that. Confirm the current
> policy at M4 and make sure the graph export to S3 is running before you rely on it
> ([D-013](./DECISION-LOG.md#d-013--infra-split-into-three-lifecycle-layers)).

---

## 5. Bootstrap layer

`[PENDING M0]` — lands with `infra/bootstrap`.

**Applied once, by hand, from your machine.** This layer creates the Terraform state bucket
that every other layer depends on, so it cannot itself use remote state. It is **never
destroyed**.

Creates: S3 state bucket (versioned, encrypted, public access blocked), GitHub OIDC provider,
`specsage-gha-plan` and `specsage-gha-deploy` IAM roles trust-scoped to
`repo:praveennish/SpecSage:*`.

```bash
cd infra/bootstrap
AWS_PROFILE=specsage terraform init
AWS_PROFILE=specsage terraform plan     # review before applying
AWS_PROFILE=specsage terraform apply
```

Expected: ~6 resources. Record the state bucket name and role ARNs from the outputs.

Then return to step 1.8 and activate the cost allocation tag once it appears.

---

## 6. Daily operation

`[PENDING M0]` — lands with `infra/modules/compute`.

The stop-start model ([D-017](./DECISION-LOG.md#d-017--stop-start-operating-model-with-snapshotrestore)):
`bootstrap` and `data` persist, `compute` comes and goes.

```bash
set -a && source .env.local && set +a   # start of every session
make up                                  # ~2 min
# ... work ...
make down                                # ~2 min
make verify-empty                        # always
```

| Command | Does | Cost effect |
|---|---|---|
| `make up` | Apply `compute`; restore Qdrant/Neo4j from the latest S3 snapshot | starts per-use billing |
| `make down` | Snapshot stateful services **first**, then destroy `compute` | returns to ~$1.30/mo |
| `make verify-empty` | List any billable resource still running | — |
| `make deploy` | Build → push to ECR → update the Lambda function | — |
| `make smoke` | Smoke tests against the live URL | — |

> **Always run `make verify-empty` after `make down`.** A half-completed destroy leaves
> orphaned billable resources and reports success. The budget alarm will eventually catch it;
> `verify-empty` catches it in ten seconds.

**Never destroy the `data` layer.** It holds the corpus, the Qdrant snapshot, and the Neo4j
export. The M4 graph costs one LLM call per chunk to rebuild — see the rebuild-cost table in
[ARCHITECTURE.md §4](./ARCHITECTURE.md#4-infrastructure-lifecycle-layers). `golden_qa.jsonl`
lives in git precisely because it cannot be rebuilt at any price.

---

## 7. Deploy and rollback

`[PENDING M0]`

### Deploy

Repo → **Actions** → **Deploy** → **Run workflow** → select environment `dev` → approve when
the environment gate prompts.

The workflow builds and pushes the image, applies Terraform, updates the function, then runs a
smoke test asserting `/health` returns 200 **and** that its `git_sha` equals the triggering
commit. A plain 200 check passes when Terraform applied cleanly but stale code is still
serving; the SHA comparison is what catches that.

### Rollback

Lambda keeps every published version. Rolling back is repointing the alias, not rebuilding:

```bash
aws lambda list-versions-by-function --function-name specsage-api \
  --query 'Versions[].[Version,LastModified]' --output table

aws lambda update-alias --function-name specsage-api \
  --name live --function-version <previous-version>
```

Then confirm:

```bash
make smoke
```

Rollback takes seconds and needs no build. If the *infrastructure* rather than the code is
broken, `git revert` the Terraform change and re-run the deploy workflow.

---

## 8. Cost incident response

The automated circuit breaker arrives at M10. Until then the levers are manual.

**If the budget alarm fires:**

1. **Stop the bleeding:** `make down` removes everything that bills per use
2. **Find it:** Cost Explorer → group by **Service**, daily granularity, last 7 days
3. **Attribute it:** group by the `Project` tag (once §1.8 is active) — an untagged spike means
   something was created outside Terraform
4. **Check the usual suspects:**

   | Symptom | Likely cause |
   |---|---|
   | Data transfer spike | CloudFront serving something large, or an egress loop |
   | Bedrock spike | A retry loop in the M4 extraction pass, or an unbounded agent loop |
   | S3 request spike | A pipeline stage re-reading the corpus per chunk |
   | ECS/Fargate hours | A batch task that never exited |

5. **Verify you're back to baseline:** `make verify-empty`, then watch Cost Explorer the next
   day — billing data lags by up to 24 hours, so "it stopped" is not observable immediately

**Hard stop if you need one:** detach `AdministratorAccess` from `specsage-admin`. Nothing new
can be created. Blunt, effective, and easily reversed.

---

## 9. Troubleshooting

### Credentials

| Symptom | Cause | Fix |
|---|---|---|
| `Unable to locate credentials` | `export` prefixes in `~/.aws/credentials`, or a missing `[specsage]` header | Strip `export`, check the section header |
| `InvalidClientTokenId` on a key you just made | Values wrapped in quotes — the parser treats `"` as the first character of the key | Remove the quotes. This error reads like expiry; it isn't. |
| `ExpiredToken` | You're on the corporate SSO profile | `export AWS_PROFILE=specsage` |
| `get-caller-identity` returns an `assumed-role/AWSReservedSSO_…` ARN | Same as above | Same as above |

### Terraform

| Symptom | Cause | Fix |
|---|---|---|
| `AWS account ID not allowed` at plan time | Credentials resolved to the wrong account | The guardrail is working. `export AWS_PROFILE=specsage`. |
| `Error acquiring the state lock` | Previous run interrupted | `terraform force-unlock <lock-id>` — verify no one else is applying first |
| `use_lockfile` unsupported | Terraform < 1.10 | `brew upgrade terraform` |
| `NoSuchBucket` on init | Bootstrap hasn't been applied | §5 |

### Application

| Symptom | Cause | Fix |
|---|---|---|
| `/health` returns `git_sha: "unknown"` locally | No commits in the repo, or `GIT_SHA` unset | Expected. Not a bug. |
| Smoke test fails on SHA mismatch | Deploy applied but stale code is serving | Check the Lambda function's image URI matches the pushed tag |
| `AccessDeniedException` from Bedrock | Model access not granted in this region | §1.6 — and confirm the region is `us-east-1` |
| `ResourceNotFoundException` naming a model | Wrong model ID form | Bedrock IDs carry an `anthropic.` prefix; see [D-028](./DECISION-LOG.md#d-028--bedrock-access-via-anthropicbedrockmantle-model-ids-verified) |
| `lint-imports` fails | Something imported an agent framework into `retrieval` | Move it to `agents/`. The contract is deliberate ([D-002](./DECISION-LOG.md#d-002--orchestration-langgraph-behind-a-framework-agnostic-agenttool-interface)). |

### CI/CD

| Symptom | Cause | Fix |
|---|---|---|
| `Not authorized to perform sts:AssumeRoleWithWebIdentity` | OIDC trust policy doesn't match the repo | Check the `sub` condition matches `repo:praveennish/SpecSage:*` |
| Deploy runs without asking for approval | The `dev` environment has no required reviewer | §3.3 |
| `terraform plan` comment never appears on the PR | Workflow lacks `pull-requests: write` permission | Check the `permissions:` block in `ci.yml` |

---

## 10. Setup verification

Run this at any point to check where you are:

```bash
./scripts/verify-setup.sh
```

It checks toolchain versions, credential resolution, account match, Bedrock model visibility,
budget existence, and the local test suite — and prints exactly which runbook step to go back
to for anything that fails.
