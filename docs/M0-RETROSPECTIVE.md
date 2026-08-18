# M0 Retrospective — "Hello World" Live on AWS

**Written to be self-contained.** Everything needed to reconstruct the story is here: the
goal, the architecture, every decision and its reasoning, every bug with its exact error text
and root cause, the AWS/GitHub/Terraform concepts involved, and the real cost numbers. A
reader with no prior context — human or model — should be able to work from this alone.

**Project:** SpecSage — agentic RAG + knowledge graph over openly-licensed computer-architecture
documentation. M0 is milestone 0 of 13.
**Account:** `941500193593` (us-east-1) · **Repo:** `github.com/praveennish/SpecSage`
**Duration:** 2026-07-28 → 2026-08-18 (part-time)
**Result:** live public HTTPS endpoint, full CI/CD, ~$0.024 spent.

---

## Contents

1. [The goal, and why it isn't trivial](#1-the-goal)
2. [What got built](#2-what-got-built)
3. [Architecture decisions — and four deviations from the original plan](#3-architecture-decisions)
4. [Every roadblock, in order](#4-roadblocks)
5. [AWS concepts and how they integrate](#5-aws-concepts)
6. [GitHub concepts and how they integrate](#6-github-concepts)
7. [Terraform concepts](#7-terraform-concepts)
8. [Cost, in detail](#8-cost)
9. [Numbers](#9-numbers)
10. [Blog angles](#10-blog-angles)

---

## 1. The goal

> Prove the deployment pipeline and docs discipline work **before any product logic exists**.
> Release checkpoint: `curl https://<url>/health` returns 200 from the public internet showing
> the **correct git SHA**.

The SHA is the whole point. A 200 proves something is running. A 200 *with the commit you just
pushed* proves the thing running is the thing you deployed. Those are different claims, and
the second one is the only one worth making — it's the difference between "the apply
succeeded" and "the new code is serving."

Every bug in §4 sits between those two statements.

---

## 2. What got built

### Live architecture

```
Browser / curl
     │  https://d3dxlxj4unjdgm.cloudfront.net
     ▼
CloudFront E38H2SZ7YVFENH          free AWS-managed TLS on *.cloudfront.net
     │                             no hourly charge, $0 idle
     ├── default behaviour ───▶ Lambda Function URL
     │                             https://nuryge5bjlt32jwkxtlm3eopga0qsdev.lambda-url.us-east-1.on.aws/
     │                                 │
     │                          Lambda specsage-api
     │                          arm64 · 1024 MB · 30 s · container image
     │                                 │
     │                          Lambda Web Adapter (/opt/extensions/)
     │                                 │  translates Lambda event ↔ HTTP
     │                          uvicorn :8000 → FastAPI → GET /health
     │
     └── /paused.html ────────▶ S3 specsage-web-941500193593 (via OAC)
         502/503/504 fallback
```

### Terraform layers

Split by **lifecycle**, not by resource type. This is the single most consequential structural
decision in M0.

| Layer | Lifecycle | Contents | State |
|---|---|---|---|
| `bootstrap` | never destroyed; applied by hand once | state bucket, OIDC provider, 2 CI roles, budget | **local** (chicken-and-egg: it creates the bucket the others use) |
| `data` | never destroyed | artifacts bucket, web bucket, ECR, CloudFront, OAC | `s3://…/data/terraform.tfstate` |
| `compute` | destroyed between sessions | Lambda, Function URL, IAM role, log group | `s3://…/compute/terraform.tfstate` |

The two halves are joined by exactly one variable: `data`'s `lambda_function_url`. Empty →
CloudFront serves the paused page. Set → it routes to Lambda. **Neither layer's state
references the other.**

### Concrete resources and ARNs

```
S3   specsage-tfstate-941500193593      Terraform state, versioned, TLS-only, lifecycle-managed
S3   specsage-artifacts-941500193593    corpus/chunks/snapshots (M1+), prevent_destroy
S3   specsage-web-941500193593          static assets, private, read only via CloudFront OAC
ECR  941500193593.dkr.ecr.us-east-1.amazonaws.com/specsage-api    IMMUTABLE tags, scan-on-push

arn:aws:iam::941500193593:oidc-provider/token.actions.githubusercontent.com
arn:aws:iam::941500193593:role/specsage-gha-plan       ReadOnlyAccess + state write
arn:aws:iam::941500193593:role/specsage-gha-deploy     scoped inline policies, no managed policy
arn:aws:iam::941500193593:role/specsage-lambda-exec    AWSLambdaBasicExecutionRole only
arn:aws:lambda:us-east-1:941500193593:function:specsage-api
arn:aws:cloudfront::941500193593:distribution/E38H2SZ7YVFENH
```

### Repository

```
service/     FastAPI — /health returns {status, service, version, git_sha, environment}
ingestion/ embedding/ graph/ retrieval/ agents/ eval/ mcp_server/ finetune/   empty, documented
infra/       bootstrap/ · data/ · compute/
tests/       31 unit + 2 smoke, markers: unit | integration | smoke
docs/        ARCHITECTURE · DECISION-LOG (28 entries) · PATTERNS · RUNBOOK · COSTS
             PROVENANCE · DECISIONS (owner-written ADRs) · runbooks/ · plans/
.github/workflows/  ci.yml (5 jobs) · deploy.yml (deploy + teardown)
```

---

## 3. Architecture decisions

The original brief specified **ALB + ECS Fargate service + ACM certificate on a registered
domain + Secrets Manager**. What shipped was **CloudFront + Lambda container + free
`*.cloudfront.net` certificate + no secrets**. Four deviations, each documented with reasoning
before implementation.

### D-007 — No NAT Gateway

Reflexive AWS design puts workloads in private subnets behind a NAT Gateway. NAT is
**~$33/month** — more than the entire rest of the stack combined.

The security property that actually matters is *no inbound path from the internet*. A security
group that accepts ingress only from the front door delivers that as effectively as a private
subnet. Private subnets additionally prevent *outbound* reach, which we do not need and would
have to pay NAT to restore.

**Saved: $33/mo.** Revisited at M10 (public exposure) and M12 (prod).

### D-010/D-011 — CloudFront's default certificate instead of a domain

The brief asked for "ALB with HTTPS" and a checkpoint of `curl https://<alb-dns>/health`.
**Those two cannot both be true.** ACM will not issue a certificate for `*.elb.amazonaws.com`;
you can only get a valid cert for a domain you control.

Three options: register a domain (~$13/yr + $0.50/mo hosted zone), run HTTP-only until M10, or
use CloudFront — the one AWS surface that terminates TLS on an **AWS-owned** hostname and
therefore ships a valid certificate for free.

CloudFront won on three counts: free valid TLS, **$0 idle** (no hourly charge, and the
perpetual free tier covers 1 TB + 10M requests/month), and it is *already* M10's required
architecture, so it is week-4 work done early rather than throwaway scaffolding.

**Cost: −$1.60/mo vs a domain.** Trade-off accepted: the URL is unmemorable and unbrandable.
Adding a domain later is one ACM cert, one `aliases` entry, one DNS record.

### D-019/D-020 — Lambda for request/response, Fargate for batch

An ALB bills **~$16.40/month whether or not a request arrives**. Scaling ECS to zero saves
$2.70 and leaves the ALB untouched — the ALB *is* the cost.

The `/health` workload is request/response with no state between invocations and no long-lived
connections. That is precisely Lambda's shape, and Lambda's free tier (1M requests + 400,000
GB-seconds/month, perpetual) covers roughly 4 million requests/month at 1024 MB.

**Fargate is not abandoned** — it returns at M1 for batch pipeline stages (ingestion, parsing,
embedding, graph extraction), where one-off tasks bill per second and a 10-minute run costs
about a cent. The split is by **workload shape**, not preference: sub-second stateless calls on
Lambda, multi-minute memory-hungry jobs on Fargate.

**Saved: $16.40/mo.** Honest cost: two compute models instead of one. That is real added
surface area and should be stated rather than hidden.

### D-013/D-017 — Three lifecycle layers, not two

The initial split was by *cost* — always-billed vs billed-while-running. That was wrong,
because it did not distinguish **stateless** from **stateful**.

Milestone artifacts have wildly different rebuild costs:

| Artifact | From | Rebuild cost |
|---|---|---|
| Raw corpus | M1 | slow; sources rate-limit and move |
| Qdrant vector index | M3 | embedding calls + tens of minutes |
| **Neo4j reference graph** | M4 | **one LLM call per chunk — dollars and hours** |
| `golden_qa.jsonl` | M7 | **irreproducible** — hand-curated |

A teardown that destroys the M4 graph to save $16 of ALB is a bad trade every single time. So:
`bootstrap` and `data` never die; `compute` is disposable; and `make down` snapshots stateful
services to S3 *before* destroying.

The side effect is better than the intent: **a stack destroyed nightly cannot accumulate
undocumented state.** Every artifact must be reconstructible from S3 or git, or it does not
survive to the next session. Most teams discover which of their state was load-bearing during
an outage.

---

## 4. Roadblocks

Fourteen distinct problems. Presented in the order encountered. Every one is a real error with
real output.

### 4.1 — AWS credentials file, two malformations at once

**Symptom, first:** `Unable to locate credentials` — as though the file were empty.
**Symptom, after first fix:** `InvalidClientTokenId` — as though the key were revoked.

**Root cause:** the file contained shell-export syntax pasted into an INI file, *and* quoted
values:

```ini
[default]
export AWS_ACCESS_KEY_ID = "ASIA..."
```

The SDK's INI parser doesn't recognise `export AWS_ACCESS_KEY_ID` as `aws_access_key_id`, so
the profile appeared empty. After stripping `export`, the parser read `"` as the first
character of the key and sent a malformed credential to STS — which rejected it with an error
identical to an expired key.

**Fix:** raw values, no `export`, no quotes.

**Lesson:** the second error is the nastier one. It points you at IAM when the problem is two
characters of punctuation. Both failure modes are now a troubleshooting table row and an
automated check in `scripts/verify-setup.sh`, which inspects the file rather than waiting for
STS to complain.

**Bonus finding:** the working credentials resolved to
`arn:aws:sts::275279264324:assumed-role/AWSReservedSSO_AWS-Common-Users-PermSet/…@rearc.io`
— a **shared corporate account** with other engineers' Terraform state buckets in it. Building
a personal portfolio project there would have meant the corpus, training data, and model
artifact were readable by everyone with account access, and a GitHub OIDC trust path from a
public repo into an employer's account. Moved to a personal account before anything was
provisioned.

### 4.2 — `.gitignore` `*.tfplan` doesn't match `tfplan`

**Symptom:** none. `git status` looked clean.

**Root cause:** `.gitignore` had `*.tfplan`, but Terraform's conventional output — used in
virtually every doc example — is `terraform plan -out=tfplan`, producing an **extensionless**
file. The pattern never matched. Plan files embed resolved variable values and full resource
attributes.

**Fix:** ignore `*.tfplan`, `tfplan`, and `tfplan.*`.

**Caught by:** a pre-push audit that ran `git check-ignore -v` on each sensitive path rather
than reading `.gitignore` and assuming.

### 4.3 — `.gitignore` `data/` swallowed `infra/data/`

**Symptom:** none. The first push reported success. 47 files committed.

**Root cause:** `.gitignore` line 36 was `data/`, intended to exclude a repo-root corpus
directory. A gitignore pattern with **no leading slash matches at any depth**, so it also
excluded `infra/data/` — the entire Terraform layer defining the live CloudFront distribution
and both S3 buckets.

```
.gitignore:36:data/    infra/data/cloudfront.tf
.gitignore:36:data/    infra/data/storage.tf
```

Six files. `git add .` skipped them silently; `git status` showed nothing amiss. Live
infrastructure had **no source of truth in version control**.

**Fix:** anchor patterns that use common words — `/data/`, `/processed/`, `/snapshots/`.

**Lesson, and the reason this is the most interesting bug in the list:** verifying a push
needs *two different questions*, and only one is answerable from git.

- "Is anything bad included?" → `git grep` over `git rev-list --all`. Easy.
- "Is anything good missing?" → **nothing in a repo records what should be there.** You have to
  enumerate the filesystem and ask git about each file.

The first push passed a full credential scan and still lost six Terraform files.

### 4.4 — Upstream tracking lost during history rewrite

**Symptom:** `git status` printed `## main` instead of `## main...origin/main`.

**Root cause:** squashing a **root** commit can't use `git reset --soft <sha>~1` — there is no
parent. The correct approach is `git checkout --orphan`, then `git branch -D main; git branch -m
main`. The rename drops the upstream link.

**Fix:** `git branch --set-upstream-to=origin/main main`.

**Why it mattered:** the push had succeeded, so nothing looked wrong. The next bare `git push`
or `git pull` would have failed with "no upstream configured."

**Pattern across 4.2–4.4:** three git problems, all of which presented as *silence*. Git is
unusually good at doing exactly what you asked and unusually bad at telling you that wasn't
what you meant.

### 4.5 — Docker buildx attestations broke the ECR lifecycle policy

**Symptom:** one `docker push` produced **three** entries in ECR.

```
ba7c6371  tag=7f808fd   57 MB    application/vnd.oci.image.INDEX.v1+json
11ad7a21  untagged      57 MB    application/vnd.oci.image.manifest.v1+json
b9caa2f4  untagged      1.7 KB   application/vnd.oci.image.manifest.v1+json
```

**Root cause:** `docker buildx build --push` attaches **provenance attestations** by default.
That forces it to publish an **OCI image index** (a manifest list) and put the tag on the
*index* — a pointer. The real 57 MB arm64 image and the attestation are untagged children.

Two consequences, one imminent and one latent:

1. **Lambda often rejects a tag resolving to an index** with
   `InvalidParameterValueException: The image manifest is not supported`.
2. **The ECR lifecycle policy would have deleted the real image.** Lifecycle rules have **no
   concept of referential integrity** — they cannot distinguish an orphaned manifest from a
   child that a tagged index depends on. The rule was "expire untagged after 1 day." Within
   ~24 hours the tag would have survived, pointing at an index with no contents, and every
   pull would fail. **With no deploy having occurred.**

**Fix, two parts:**
- `--provenance=false --sbom=false` on every build (CI, deploy workflow, Makefile). Lambda is
  single-platform; there is no reason to publish a manifest list.
- Lifecycle untagged window widened 1 day → **14 days** as defence in depth, with the reasoning
  in the Terraform.

Verification target: **one row**, media type `…manifest.v2+json`, not `index`.

### 4.6 — CloudFront silently ignored `minimum_protocol_version`

**Symptom:** every `terraform plan` on the `data` layer showed the same change forever:

```
~ minimum_protocol_version = "TLSv1" -> "TLSv1.2_2021"
```

Apply succeeded. Value never changed. Next plan showed it again.

**Root cause:** with `cloudfront_default_certificate = true`, CloudFront **pins** the reported
minimum protocol version to `TLSv1` and ignores the setting. Only a custom domain + ACM
certificate can set it.

**Why a perpetual diff is worse than cosmetic:** a plan that can never return clean cannot be
used as a drift check, and it trains you to skim plan output — which is exactly how the *next*
unexpected change gets missed.

**Was it a real security gap?** Tested rather than assumed:

```
TLS 1.0 → connection refused
TLS 1.2 → 200
TLS 1.3 → 200
```

AWS has already deprecated TLS 1.0/1.1 on `*.cloudfront.net`, so the reported `TLSv1` is
nominal. Posture fine; the config was lying.

**Fix:** remove the attribute, with the empirical result recorded inline. `terraform plan
-detailed-exitcode` now returns **0**, making it usable as a genuine drift check.

### 4.7 — Lambda `Runtime.InvalidEntrypoint` for a file that exists

**Symptom:**

```
Runtime.InvalidEntrypoint
Error: fork/exec /app/.venv/bin/uvicorn: no such file or directory
```

The file was demonstrably present:

```
-rwxr-xr-x 1 specsage specsage 301 /app/.venv/bin/uvicorn
```

**Root cause:** the Dockerfile built the venv at `WORKDIR /build` and copied it to `/app`.
**Python venv console scripts bake an absolute shebang:**

```
#!/build/.venv/bin/python      ← does not exist in the runtime stage
```

`exec()` fails with ENOENT on the missing **interpreter**, but the kernel attributes the error
to the **script**. So the message names a file that is plainly there.

**Fix, three parts:**
- `WORKDIR /app` in the build stage so paths match
- `UV_PROJECT_ENVIRONMENT=/app/.venv` pinning it explicitly, so a future `WORKDIR` edit cannot
  silently reintroduce the mismatch
- `CMD ["python", "-m", "uvicorn", …]` — `-m` never touches a console-script shebang
- **A build-time assertion**, so this fails the *build* rather than the invoke:

```dockerfile
RUN test -x /app/.venv/bin/uvicorn \
    && head -1 /app/.venv/bin/uvicorn | grep -q '^#!/app/.venv/bin/python' \
    && /app/.venv/bin/uvicorn --version
```

**How it was found:** `aws lambda invoke` — deliberately bypassing the Function URL. See 4.8.

### 4.8 — Function URL 403, and an AWS rule change

**Symptom:**

```json
{"Message": "Forbidden. For troubleshooting Function URL authorization issues, see: …"}
```

`x-amzn-ErrorType: AccessDeniedException`. Signed requests failed identically.

**Everything inspected looked correct:**

```
AuthType: NONE
resource policy: Effect Allow · Principal "*" · Action lambda:InvokeFunctionUrl
                 Condition StringEquals lambda:FunctionUrlAuthType = NONE
```

Four rounds of inspection went into the IAM policy — because the error said "authorization"
and the AWS doc link said "authorization." Every check passed.

**The breakthrough** was `aws lambda invoke`, bypassing the URL entirely, which surfaced the
*container* failure of 4.7. The 403 had been masking an init failure. Fixing the Dockerfile
made the container healthy — **and the 403 persisted**, proving there were genuinely two bugs.

**Actual root cause**, from the AWS docs page the error itself linked to:

> **Starting in October 2025, new function URLs will require both `lambda:InvokeFunctionUrl`
> and `lambda:InvokeFunction` permissions.**
>
> If a function's resource-based policy doesn't grant [both], users get a **403 Forbidden**…
> **even if the function URL uses the `NONE` auth type.**

The policy had only the first. It matched AWS's own documented example — the pre-October-2025
example, which is presumably also where the Terraform provider's auto-created statement came
from.

**Fix:** declare both statements explicitly:

```hcl
resource "aws_lambda_permission" "url_invoke_url" {
  action                 = "lambda:InvokeFunctionUrl"
  principal              = "*"
  function_url_auth_type = "NONE"
}

resource "aws_lambda_permission" "url_invoke_function" {
  action                   = "lambda:InvokeFunction"
  principal                = "*"
  invoked_via_function_url = true   # ← requires AWS provider 6.x
}
```

`invoked_via_function_url` does not exist in provider 5.x, so the layer was upgraded to
`~> 6.0` (6.60.0). **That condition is load-bearing:** without it, granting `InvokeFunction` to
`*` would let *any* AWS principal invoke the function directly by ARN, bypassing the URL
entirely. With it, the Function URL is the only way in.

**Lesson:** when something is correct by every check you know and still fails, question whether
the checks are current — not whether you performed them carefully enough.

### 4.9 — A regression introduced mid-fix

**Symptom:** after applying the permission fix, `/health` reported the *old* SHA.

**Root cause:** `terraform.tfvars` still pinned `image_tag = "7f808fd"` — the broken image. The
apply dutifully reverted the function to it. Visible in the plan output as
`aws_lambda_function.api will be updated in-place`, which was skimmed past.

**Fix:** update the tfvars, re-apply.

**Worth noting:** this is precisely the failure that `image_tag` having **no default** is
designed to make visible. The variable is required specifically so "which commit is deployed"
is never implicit.

### 4.10 — Bedrock: `ListFoundationModels` is not an access check

**Symptom:** the setup verification reported all four model IDs present. The first actual
invocation returned `AccessDeniedException`.

**Root cause:** `ListFoundationModels` reports what **exists in the region**, not what you are
entitled to call. It returned four IDs on an account that could invoke two.

**Second finding, same investigation:** Claude models on Bedrock **require a cross-region
inference profile prefix**; Titan does not.

```
anthropic.claude-haiku-4-5-20251001-v1:0      → rejected for on-demand throughput
us.anthropic.claude-haiku-4-5-20251001-v1:0   → works
amazon.titan-embed-text-v2:0                  → works with the bare ID
```

Three inconsistencies across four IDs: an `anthropic.` provider prefix that first-party IDs
lack; the 5-family bare while Haiku 4.5 carries a dated suffix; and a `us.` prefix required
for one family and not the other.

**Fix:** `scripts/check-bedrock.sh` makes a real 16-token call per model, auto-retries with the
`us.` prefix on the specific throughput error, and **prints the exact ID form that worked** —
which is the value to pin in config. IDs are discovered, never derived by rule.

**Third finding:** `anthropic.claude-sonnet-5` and `claude-opus-5` return
`AccessDeniedException: … is not available for this account` on both bare and profile IDs,
while the inference profiles exist and are `ACTIVE`. An account-entitlement gap, not a
permissions or format problem. Teacher synthesis moved to the verified
`us.anthropic.claude-sonnet-4-6`.

### 4.11 — OIDC: GitHub issues ID-qualified subject claims

**Symptom:**

```
Error: Could not assume role with OIDC: Not authorized to perform sts:AssumeRoleWithWebIdentity
```

**Three rounds of investigation, all finding nothing wrong:**

- Repo casing vs trust policy — exact match (`praveennish/SpecSage`)
- Repository variables — present, correct values, repository-scoped
- OIDC provider — correct URL, audience `sts.amazonaws.com`
- Trust policy — inspected at byte level, no whitespace or case drift

The failing request carried the correct role ARN and audience. Every operand looked right.

**The fix was to print the comparison instead of re-examining the operands.** A debug step
decoded the OIDC token's claims (claims only, never the token — `sub` is not secret):

```
sub          = repo:praveennish@82397891/SpecSage@1314955214:ref:refs/heads/main
aud          = sts.amazonaws.com
repository   = praveennish/SpecSage
event_name   = push
```

**Root cause:** GitHub issues **ID-qualified subject claims** —
`repo:<login>@<owner_id>/<name>@<repo_id>:<context>` — not the classic
`repo:<owner>/<name>:<context>` the trust policy matched. Confirmed against the GitHub API:
owner ID `82397891`, repo ID `1314955214`.

It is a **better** security property: numeric IDs survive renames and transfers, so a renamed
repo cannot carry its permissions with it and a new repo squatting the old name cannot claim
them. It just doesn't match a policy written for the classic shape — and AWS's denial never
echoes the subject it refused.

**Fix:** both forms enumerated explicitly in both roles' trust policies, generated from a
`locals` block:

```
plan:   repo:praveennish/SpecSage:pull_request
        repo:praveennish/SpecSage:ref:refs/heads/main
        repo:praveennish@82397891/SpecSage@1314955214:pull_request
        repo:praveennish@82397891/SpecSage@1314955214:ref:refs/heads/main

deploy: repo:praveennish/SpecSage:environment:dev
        repo:praveennish@82397891/SpecSage@1314955214:environment:dev
```

Enumerated, not wildcarded. `repo:praveennish*/SpecSage*:…` covers both in one pattern but also
matches `praveennish-evil` — a trust policy is the wrong place to save four lines.

### 4.12 — Terraform backend cannot use variables

**Symptom, in CI only:**

```
Error: failed to get shared config profile, specsage
```

**Root cause:** the backend block hardcoded `profile = "specsage"`. **Backend blocks are
evaluated before variables exist**, so `profile = var.aws_profile` is impossible — and a
hardcoded profile fails on a runner with no `~/.aws/credentials`.

The provider was already handled via `TF_VAR_aws_profile: ""`. The backend was not, and cannot
be.

**Fix:** remove `profile` from the backend entirely; let the environment resolve credentials.

| | Source |
|---|---|
| Local | `AWS_PROFILE=specsage`, exported by the Makefile |
| CI | `AWS_ACCESS_KEY_ID`/`SECRET`/`SESSION_TOKEN` injected by the OIDC action |

**The wrong-account guard is unaffected** — `allowed_account_ids` still fails at plan time, and
mismatched credentials cannot read the state bucket at all.

### 4.13 — Bootstrap cannot be planned from CI

**Symptom:** `terraform plan` failed for `bootstrap` while `data` and `compute` passed.

**Two independent causes:**

1. `budget_alert_email` has **no default** and `terraform.tfvars` is gitignored — CI has no
   value for a required variable.
2. **Bootstrap has no backend.** It keeps local state by design, because it *creates* the
   bucket every other layer stores state in. A runner has no state file, so even with variables
   supplied, plan would have proposed **creating all 15 resources** — including a state bucket
   carrying `prevent_destroy` and an OIDC provider that already exists.

The second is the real problem. A confidently wrong plan on every PR is worse than no plan: it
trains you to skim, which is the habit that lets a genuine change slip through.

**Fix:** remove `bootstrap` from the plan matrix; add a validate-only job using
`terraform init -backend=false`, which touches no state and makes no AWS call. That is the only
honest claim CI can make about a hand-applied layer: *the config is syntactically valid.*

### 4.14 — The smoke test's first real firing

**Symptom:** `test_deployed_sha_matches_expected` failed.

```
git HEAD:  45523eb
deployed:  a8ef1b4
```

**Not a bug.** The check was designed to catch "apply succeeded but stale code is still
serving." Its first firing caught something else entirely: committing a fix does not deploy
it. A human sequencing error, not the machine failure it was built for.

Fairly typical — assertions usually earn their keep against mistakes nobody modelled.

---

## 5. AWS concepts

### IAM roles, trust policies, and ARNs

An **ARN** is AWS's globally unique resource identifier:

```
arn:aws:iam::941500193593:role/specsage-gha-deploy
│   │   │    │            │
│   │   │    │            └── resource: type/name
│   │   │    └── account ID (IAM is global, so no region)
│   │   └── service
│   └── partition (aws | aws-cn | aws-us-gov)
└── literal
```

Regional services include the region: `arn:aws:lambda:us-east-1:941500193593:function:specsage-api`.
CloudFront is global, so its ARN omits the region:
`arn:aws:cloudfront::941500193593:distribution/E38H2SZ7YVFENH`.

ARNs are **not secrets**. They appear in every policy, contain the account ID, and are useless
without credentials. This is why the CI role ARNs are GitHub *variables* rather than *secrets* —
keeping them visible in workflow logs is what makes a failed role assumption debuggable.

**A role has two policies, and conflating them is the commonest IAM confusion:**

| | Answers | Lives on |
|---|---|---|
| **Trust policy** | *Who may become this role?* | the role (`AssumeRolePolicyDocument`) |
| **Permission policy** | *What may this role do?* | attached managed/inline policies |

In M0, all the security lives in the trust policy. Both CI roles could have identical
permissions and still differ enormously in power, because they trust mutually exclusive
subjects.

### OIDC federation — no long-lived credentials

Instead of storing an AWS access key in GitHub:

```
1. Workflow requests an OIDC token from GitHub          (needs permissions: id-token: write)
2. GitHub signs a JWT containing claims:
     iss = https://token.actions.githubusercontent.com
     aud = sts.amazonaws.com
     sub = repo:praveennish@82397891/SpecSage@1314955214:ref:refs/heads/main
3. Workflow calls sts:AssumeRoleWithWebIdentity with the JWT and a role ARN
4. AWS validates the signature against the registered OIDC provider
5. AWS evaluates the role's trust policy conditions against the claims
6. STS returns credentials valid for 1 hour
```

The `sub` claim is where least privilege happens. A trust policy that only checks the
repository lets **any** workflow on **any** branch — including one added in a fork's pull
request — assume the role.

```
gha-plan    StringLike  sub ∈ {…:pull_request, …:ref:refs/heads/main}   ReadOnlyAccess
gha-deploy  StringEquals sub = …:environment:dev                        scoped write
```

**The approval gate is enforced by IAM, not by workflow YAML.** GitHub only mints a token with
`environment:dev` after the environment's protection rules are satisfied. Delete
`environment: dev` from `deploy.yml` and the job cannot authenticate at all — it does not
silently proceed ungated. A rule that lives only in YAML can be edited away in the same PR that
abuses it; a trust policy cannot.

### S3 — four settings that matter

```hcl
versioning                  Enabled                  console default: OFF
server_side_encryption      AES256 + bucket key
public_access_block         all four true
object_ownership            BucketOwnerEnforced      disables ACLs entirely
bucket_policy               Deny s3:* when aws:SecureTransport = false
lifecycle_configuration     expire noncurrent versions
```

Versioning defaulting to off is the one people miss on state buckets — without it a bad state
write is unrecoverable. The TLS-only policy has no console checkbox at all; S3 accepts
plaintext HTTP by default.

`prevent_destroy = true` on the artifacts bucket is a Terraform-side protection with no console
equivalent.

### CloudFront + Origin Access Control

The web bucket is **fully public-access-blocked and served on the internet simultaneously**:

```
direct S3 GET  → HTTP 403
via CloudFront → HTTP 200
```

OAC has CloudFront sign each origin request with SigV4 as the `cloudfront.amazonaws.com`
service principal. The bucket policy allows that principal — **scoped by `AWS:SourceArn` to
this one distribution**:

```hcl
condition {
  test     = "StringEquals"
  variable = "AWS:SourceArn"
  values   = [aws_cloudfront_distribution.main.arn]
}
```

Without that condition, **any CloudFront distribution in any AWS account** could read the
bucket — the service principal is shared globally. That single condition is the security
boundary.

### CloudFront error mapping — state-dependent, and subtle

```hcl
dynamic "custom_error_response" {
  for_each = local.compute_up ? [502, 503, 504] : [403, 404]
  ...  response_code = 200, response_page_path = "/paused.html"
}
```

- **Compute down** → every path resolves to S3, which holds only `paused.html`, so `/health`
  would return raw S3 404 XML. Map 403/404.
- **Compute up** → map **only** 502/503/504 (CloudFront couldn't reach Lambda). Mapping 404
  here would rewrite the API's own "not found" to a 200 paused page, masking real results from
  every client including M8's MCP tools.

Verified: with compute up, `/nonexistent` returns **404**, not the paused page.

### Lambda container images + the Web Adapter

`package_type = "Image"` pulls from ECR (10 GB limit vs 250 MB for zip). The interesting part
is that **the FastAPI app knows nothing about Lambda**:

```dockerfile
COPY --from=public.ecr.aws/awsguru/aws-lambda-adapter:0.8.4 \
     /lambda-adapter /opt/extensions/lambda-adapter
```

Anything in `/opt/extensions/` is a **Lambda extension** — a process Lambda starts alongside
your container. The adapter registers as the handler and on each invocation translates the
Lambda event into an HTTP request to `localhost:8000`, then the response back.

This is the **Adapter** pattern textbook-straight: two incompatible interfaces joined by a
translator, neither side modified. Also a **Sidecar**.

The payoff is concrete: `docker run -p 8000:8000` and Lambda run the *same* uvicorn process
serving the same code. No handler shim, no Lambda-specific branch, so local and deployed
behaviour cannot silently diverge.

**Configuration worth knowing:**

| Setting | Value | Default | Why |
|---|---|---|---|
| `memory_size` | 1024 MB | 128 | memory **is** the CPU dial on Lambda; 128 cannot boot the container, 512 roughly doubles cold start |
| `architectures` | `["arm64"]` | x86_64 | Graviton, ~20% cheaper; must match `--platform` or you get `Runtime.InvalidEntrypoint` |
| `timeout` | 30 s | 3 | 3 s cannot cover a container cold start |

Observed: cold start ~3–6 s, warm ~50 ms, through CloudFront ~0.83 s.

### ECR — immutability as a correctness property

```hcl
image_tag_mutability = "IMMUTABLE"
scan_on_push         = true
```

With `MUTABLE`, `docker push :abc123` can silently replace what `abc123` points at — and the
deploy smoke test's SHA assertion would pass while serving different code. **Immutability is
what makes "the SHA identifies the artifact" true rather than aspirational.**

Consequence: re-pushing a tag fails. That is correct — one commit, one image. Rebuilding means
a new commit.

### CloudWatch Logs — the silent cost leak

The log group is created **explicitly**, before the function:

```hcl
resource "aws_cloudwatch_log_group" "api" {
  name              = "/aws/lambda/specsage-api"   # Lambda writes here and nowhere else
  retention_in_days = 7
}
```

If Lambda creates it on first invoke, it lands with retention **Never expire** and there is no
way to set retention at creation time from the Lambda side. Logs then accumulate forever at
$0.03/GB/month. This is the most common silent cost leak in serverless AWS.

### AWS Budgets

```
$10 monthly cost budget
alerts at 50% actual, 100% actual, 100% FORECAST
```

The forecast alert is the useful one — actual alerts tell you money is gone; forecast alerts
fire on trajectory. $10 against a ~$1.30/mo baseline is a deliberate tripwire that should
never fire.

---

## 6. GitHub concepts

### Actions structure

```yaml
concurrency:
  group: ci-${{ github.ref }}
  cancel-in-progress: true
```

Push three times to a PR and you'd otherwise have three full runs racing. Grouping by ref and
cancelling means only the latest commit's run survives.

```yaml
permissions:
  contents: read          # workflow default

# elevated only inside the terraform job:
  id-token: write         # request an OIDC token
  pull-requests: write    # post the plan comment
```

Three of five jobs cannot request an AWS token at all. If someone slips a credential-exfil step
into the lint job, there is no token to steal.

### Variables vs secrets vs environment scope

Three scopes exist and two are easy to confuse:

| Scope | Visible to |
|---|---|
| **Repository** variable | every job |
| **Environment** variable | only jobs declaring `environment: <name>` |
| Secret | masked in logs |

The CI terraform job deliberately declares **no** environment — a read-only plan should not
consume the deploy approval gate, and PR-triggered jobs must not receive a token the *deploy*
role trusts. That means it needs **repository** variables. Both scopes live in the same UI, one
tab apart.

There are **no secrets in this repository.** OIDC replaced them.

### Matrix strategy

```yaml
strategy:
  fail-fast: false
  matrix:
    layer: [data, compute]
```

`fail-fast: false` is deliberate — the default cancels siblings on first failure, so a broken
`compute` plan would hide whether `data` was fine. You want all answers.

### Environments as an auth mechanism

The `dev` environment does two jobs at once:

1. **Protection rule** — required reviewer pauses the deploy (public repos on the free plan;
   private repos need Pro)
2. **Claim minting** — GitHub adds `environment:dev` to the OIDC token's `sub`

The second is what makes the gate cryptographic rather than procedural.

### PR comments that don't accumulate

```javascript
const marker = `<!-- tf-plan-${layer} -->`;
const existing = comments.find(c => c.body.includes(marker));
existing ? updateComment(...) : createComment(...)
```

Without the marker + update-in-place, a 10-commit PR ends with 30 plan comments and nobody
reads any of them.

---

## 7. Terraform concepts

### State, and why bootstrap is different

`bootstrap` uses **local state** because it creates the S3 bucket every other layer stores state
in — a genuine chicken-and-egg. It is applied by hand, once. That is also why it cannot be
planned from CI (§4.13).

`data` and `compute` use S3 with `use_lockfile = true` — **Terraform ≥1.10 stores the lock in
S3 itself**, so no DynamoDB table. One fewer resource, one fewer IAM statement, $0.25/mo saved.
Nearly every tutorial written before late 2024 still prescribes the DynamoDB table.

That is also why the state-access IAM policy needs `s3:DeleteObject` — releasing the lock is
deleting the lockfile.

### The wrong-account guard

```hcl
provider "aws" {
  allowed_account_ids = [var.aws_account_id]
}
```

Fails at **plan** time if credentials resolve elsewhere. With two AWS profiles on one laptop
(corporate SSO on `default`, personal on `specsage`), this makes applying into the wrong
account impossible rather than merely discouraged. The Makefile asserts the account ID too.

### `depends_on` — dependencies Terraform cannot infer

Terraform builds its graph from **references**. A dependency that exists in AWS but not in your
HCL is invisible to it:

```hcl
depends_on = [
  aws_cloudwatch_log_group.api,              # else Lambda auto-creates it, never-expire
  aws_iam_role_policy_attachment.lambda_basic, # else the function logs nothing until next deploy
]
```

Nothing in the function config references either resource, so without `depends_on` Terraform is
free to create them in any order.

### `-detailed-exitcode`

```
0  no changes
1  error
2  changes present
```

Only `1` fails CI — exit 2 is normal on a PR that edits infrastructure. Without this flag, plan
returns 0 for both "clean" and "changes" and you lose the distinction. It also makes
"the plan is dirty" an *alarm* rather than background noise — which is why the perpetual
CloudFront diff (§4.6) was worth fixing even though the security posture was fine.

Two bash details in the same step:

- `${PIPESTATUS[0]}` rather than `$?` — piping through `tee` means `$?` is *tee's* exit code
- `-lock=false` on plan — plan is read-only; without this a CI plan blocks on a concurrent
  local apply

### Provider version pinning

`compute` runs AWS provider `~> 6.0` (6.60.0) while the others run `~> 5.80`. The 6.x line was
required for `aws_lambda_permission.invoked_via_function_url` (§4.8). Per-layer lock files make
this possible without a big-bang upgrade.

---

## 8. Cost

### Where the money didn't go

| Avoided | Saved/mo | Decision |
|---|---|---|
| NAT Gateway | $33.00 | D-007 |
| Application Load Balancer | $16.40 | D-019 |
| Self-hosted Qdrant + EFS | $10.00 | D-021 (deferred to M3) |
| Always-on Fargate service | $2.70 | D-019 |
| Route 53 zone + domain | $1.60 | D-010/D-011 |
| DynamoDB state lock table | $0.25 | D-006 |
| **Total avoided** | **$63.95/mo** | |

### What actually runs

| Resource | Billing | Est. $/mo |
|---|---|---|
| CloudFront | per request/GB, **no hourly charge** | $0.00 (free tier: 1 TB + 10M req) |
| Lambda | per request + GB-second | $0.00 (free tier: 1M req + 400k GB-s) |
| S3 × 3 | per GB + requests | ~$0.10 |
| ECR | per GB | ~$0.10 |
| CloudWatch Logs | per GB, 7-day retention | ~$0.50 |
| IAM, OIDC provider, Budgets | free | $0.00 |
| **Total** | | **~$0.70/mo** |

At 1024 MB, a 100 ms request costs 0.1 GB-s — roughly **4 million requests/month** before
Lambda charges anything.

### Actual

**Month-to-date (Aug 1–18): $0.024.**

Almost entirely S3 request charges. CloudFront never left the free tier; Lambda never left the
free tier. That figure covers a live public HTTPS endpoint, a container registry, three S3
buckets, a CDN, and every build and deploy.

### The estimate's journey

| Plan | Idle $/mo | Change |
|---|---|---|
| v1 | 22.35 | ALB + always-on Fargate, no NAT |
| v2 | 2.65 | persistent/ephemeral split, domain added |
| v3 | 1.06 | domain dropped, CloudFront default TLS |
| **v4** | **~0.70** | ALB deleted, Qdrant Cloud, free-tier GPU, model right-sizing |

**Three of four revisions were cost-driven, and every one made the architecture *simpler*** —
fewer always-on components, fewer self-hosted services, fewer things to operate. Cost pressure
acted as a forcing function toward a design that is easier to defend, not a degraded one.

Projected full project (M0–M13): **~$35**, mostly Bedrock tokens.

---

## 9. Numbers

```
Duration                    3 weeks part-time
Commits                     4 (history squashed once)
Files                       53
Tests                       31 unit + 2 smoke
Terraform files             12 across 3 layers
AWS resources               ~35
Distinct bugs               14
CI jobs                     5
Docs                        8 files, incl. 28-entry decision log, 15-pattern catalogue
Spend                       $0.024
Deployed SHA == HEAD        ✅
Drift (all 3 layers)        exit=0
```

---

## 10. Blog angles

Each of these is a standalone piece; the material is above.

**"Your error message is lying to you: five AWS bugs that reported the wrong thing"**
`Runtime.InvalidEntrypoint` naming a file that exists (§4.7). A Function URL 403 that was a
container crash (§4.8). `InvalidClientTokenId` that was a quotation mark (§4.1). A plan that
applied successfully and changed nothing (§4.6). A `.gitignore` that silently deleted six files
from a commit (§4.3). **Common thread: the failure mode of infrastructure tooling is rarely an
error — it's a success message describing something other than what you asked for.**

**"I removed the load balancer, the NAT gateway, and the domain — and the architecture got
better"** — $63.95/mo of avoided cost where every removal also *simplified* the system (§3, §8).
The counter-argument (two compute models) is stated honestly.

**"The 403 that wasn't about permissions"** — a full debugging narrative: four rounds of IAM
inspection, all correct, resolved by bypassing the layer that reported the error, then a
one-line note in AWS's docs about an October 2025 rule change (§4.7 + §4.8).

**"GitHub OIDC and the subject claim nobody told you changed"** — ID-qualified subjects, why
they're more secure, and why every trust policy example on the internet is now incomplete
(§4.11). Includes the token-claim debug step.

**"Verifying a git push needs two questions, and only one is answerable"** — §4.3. Security
scanning is easy; completeness checking has no tooling because nothing in a repo records what
should be there.

**"Zero credentials: OIDC, trust policies, and gates that YAML can't bypass"** — §5, §6. The
architectural point: the approval gate lives in an IAM trust condition, so deleting the YAML
line breaks authentication rather than removing the gate.

**"A public HTTPS endpoint for $0.024/month"** — the CloudFront-default-certificate trick, the
three-layer lifecycle split, and what "$0 idle" actually requires (§3, §8).

**Recurring theme worth naming explicitly:** four of the CI failures were code that was correct
locally and wrong in CI, because the laptop had something the runner didn't — an AWS profile, a
tfvars file, a state file, a venv at the expected path. None were bugs locally. They were
invisible dependencies on an environment configured by months of small decisions. **That is the
argument for CI beyond running tests: it's the only place "works on my machine" gets falsified
by something other than a colleague complaining.**
