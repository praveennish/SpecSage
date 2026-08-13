# M0 — Compute layer: your build

**Owner: Praveen.** I review, I don't write it.

You are building the piece that closes M0: a Lambda container function serving the FastAPI app,
behind a Function URL, wired into the CloudFront distribution that already exists.

**Why this one is yours.** Everything else in M0 is Terraform boilerplate and IAM — work you
have done a hundred times. Lambda *container images*, Function URLs, and the CloudFront-to-
Lambda origin handoff are a different deployment model from ECS Fargate, and this is the layer
every later milestone deploys through. Writing it once yourself is worth more than reviewing
mine.

**Timebox: 75 minutes.** If you are past 45 and fighting packaging rather than learning
something, hand it back.

---

## The approach: build by hand, then codify

Four phases, deliberately in this order:

| Phase | What | Why this order |
|---|---|---|
| 1 | Push an image to ECR | Lambda cannot be created from a container image that does not exist |
| 2 | Build the function **in the console** | You see every field, every default, and what AWS fills in when you don't |
| 3 | Write the Terraform to match | You already know what the answer looks like, so you are encoding knowledge rather than guessing |
| 4 | Destroy the console version, apply Terraform, verify identical | Proves the code is the source of truth, not a plausible-looking approximation |

Phase 4 is the one people skip. It is the one that catches "the console set a default I didn't
know about and my Terraform silently differs."

---

## Phase 1 — Build and push the image (10 min)

```bash
cd "/Users/praveennishchal/Documents/Agentic AI roadmap/SpecSage"
export AWS_PROFILE=specsage
ACCOUNT=941500193593
REGION=us-east-1
REPO=$ACCOUNT.dkr.ecr.$REGION.amazonaws.com/specsage-api
SHA=$(git rev-parse --short HEAD)

aws ecr get-login-password --region $REGION | docker login --username AWS --password-stdin $ACCOUNT.dkr.ecr.$REGION.amazonaws.com

docker buildx build \
  --platform linux/arm64 \
  --provenance=false \
  --sbom=false \
  --build-arg GIT_SHA=$SHA \
  -t $REPO:$SHA \
  --push .
```

> ### `--provenance=false --sbom=false` is not optional here
>
> Without them, `docker buildx --push` attaches provenance attestations, which forces it to
> publish an **OCI image index** (a manifest list) and put your tag on *that*. One push then
> produces three manifests:
>
> ```
> ba7c6371  tag=7f808fd   57MB   oci.image.INDEX.v1+json      <- tag points here
> 11ad7a21  untagged      57MB   oci.image.manifest.v1+json   <- the real arm64 image
> b9caa2f4  untagged      1.7KB  oci.image.manifest.v1+json   <- attestation
> ```
>
> Two things break:
>
> 1. **Lambda may reject the index.** It wants a concrete image manifest; a tag resolving to
>    an index is a common source of `InvalidParameterValueException: The image manifest is not
>    supported` at function-create time.
> 2. **The ECR lifecycle policy deletes the real image.** Lifecycle rules have no referential
>    integrity — they cannot tell a child manifest from an orphan. An untagged-expiry rule
>    removes `11ad7a21`, the tag survives pointing at an index with no contents, and every
>    pull fails with no deploy having happened.
>
> Lambda is single-platform. You do not need a manifest list, so do not publish one.

Verify you got **exactly one row**, tagged, media type `manifest` — not `index`:

```bash
aws ecr describe-images --repository-name specsage-api \
  --query 'imageDetails[].{Tags:imageTags,Media:imageManifestMediaType,Size:imageSizeInBytes}' \
  --output table
```

Because the repository is `IMMUTABLE`, re-pushing the same SHA requires deleting first:

```bash
aws ecr batch-delete-image --repository-name specsage-api \
  --image-ids $(aws ecr list-images --repository-name specsage-api \
    --query 'imageIds[].imageDigest' --output text | tr '\t' '\n' \
    | sed 's/^/imageDigest=/' | tr '\n' ' ')
```

**`--platform linux/arm64` is deliberate.** Graviton Lambda is ~20% cheaper than x86 for
identical work, and your Mac is arm64, so the build is native rather than emulated. The
function's `architectures` must match the image or it fails at invoke with a confusing
`Runtime.InvalidEntrypoint`.

**Tag with the SHA, not `latest`.** The repository is `IMMUTABLE`, so pushing the same tag
twice is rejected. That is the point: one commit, one image, forever
(**Immutable Infrastructure**, `docs/PATTERNS.md` P-04). It is also what makes the deploy
smoke test's SHA assertion meaningful.

Verify:

```bash
aws ecr describe-images --repository-name specsage-api \
  --query 'imageDetails[].[imageTags[0],imageSizeInBytes]' --output table
```

---

## Phase 2 — Build it in the console (25 min)

### 2a — Execution role

**IAM → Roles → Create role → AWS service → Lambda**

- Attach `AWSLambdaBasicExecutionRole` (CloudWatch Logs write only)
- Name: `specsage-lambda-exec`

That managed policy is the whole permission set for M0. The function talks to nothing but
CloudWatch. Bedrock, S3, and Secrets Manager permissions arrive at M3 when something actually
needs them — **Least Privilege** (P-02), applied as "add when needed", not "grant now in case".

### 2b — Log group

**CloudWatch → Log groups → Create log group**

- Name: `/aws/lambda/specsage-api` — this exact path, Lambda will not use another
- Retention: **7 days**

> **Console default divergence.** If you skip this, Lambda creates the log group on first
> invoke with retention **Never expire**. Logs then accumulate forever at $0.03/GB/month. This
> is the single most common silent cost leak in serverless AWS. Creating it yourself first is
> the only way to control the setting.

### 2c — The function

**Lambda → Functions → Create function → Container image**

| Field | Value | Console default | Why it differs |
|---|---|---|---|
| Function name | `specsage-api` | — | |
| Container image URI | Browse → `specsage-api` → your SHA tag | — | Never `latest` |
| Architecture | **arm64** | x86_64 | Must match the image; also cheaper |
| Execution role | Use existing → `specsage-lambda-exec` | Creates a new one | Reuse, so Terraform owns one role |

Then **Configuration → General configuration → Edit**:

| Field | Value | Default | Why |
|---|---|---|---|
| Memory | **1024 MB** | 128 MB | 128 MB cannot start a Python container. Memory also scales CPU — 1024 MB is roughly one full vCPU, which halves cold start. |
| Timeout | **30 s** | 3 s | 3 s is not enough for a container cold start. 30 s is right for `/health`; M6 synthesis will need more. |
| Ephemeral storage | 512 MB | 512 MB | Same |

### 2d — Function URL

**Configuration → Function URL → Create function URL**

- Auth type: **NONE** for now
- CORS: leave off

Test it:

```bash
curl -s https://<your-function-url>/health | python3 -m json.tool
```

You should get `status: ok` and your git SHA. **First call takes 3–6 seconds** — that is the
container cold start. Call it again and it will be ~50 ms.

> ### Auth NONE is a deliberate, temporary compromise — understand it before moving on
>
> `NONE` means the Function URL is **publicly invokable by anyone who learns it**, bypassing
> CloudFront entirely. For `/health` that is harmless. It would not be at M6, when `/answer`
> spends Bedrock money per call.
>
> The production answer is **`AWS_IAM` auth + a CloudFront Origin Access Control for Lambda
> Function URLs** — CloudFront signs each origin request with SigV4, and direct calls get 403.
> Exactly the pattern already protecting the S3 web bucket, applied to a different origin type.
>
> **Do NONE first** to get a green checkpoint with one variable in play, then tighten to
> `AWS_IAM` in Phase 5. Two changes at once means you cannot tell which one broke it.

---

## Phase 3 — Write the Terraform (25 min)

Create `infra/compute/` with the same file conventions as `infra/data/`. Read that layer
first — `versions.tf` shows the backend block, the provider guard, and the tagging you should
mirror.

### Backend

```hcl
backend "s3" {
  bucket       = "specsage-tfstate-941500193593"
  key          = "compute/terraform.tfstate"   # <- distinct key, same bucket
  region       = "us-east-1"
  profile      = "specsage"
  encrypt      = true
  use_lockfile = true
}
```

### What it must create

| Resource | Requirements |
|---|---|
| `aws_iam_role` | Trust policy for `lambda.amazonaws.com`; name `specsage-lambda-exec` |
| `aws_iam_role_policy_attachment` | `AWSLambdaBasicExecutionRole` |
| `aws_cloudwatch_log_group` | `/aws/lambda/specsage-api`, `retention_in_days = var.log_retention_days` |
| `aws_lambda_function` | `package_type = "Image"`, `image_uri`, `architectures = ["arm64"]`, memory 1024, timeout 30, `GIT_SHA` env var |
| `aws_lambda_function_url` | `authorization_type = "NONE"` (Phase 5 changes this) |

### Required inputs

`image_tag` — the SHA to deploy. Do **not** default it to `latest`; make the caller pass it, so
"which commit is deployed" is always explicit.

### Required outputs

`function_url`, `function_name`, `function_arn`.

`function_url` is what you feed to the data layer.

### Four things that will bite you

1. **`depends_on` the log group.** Without it, Terraform may create the function first, Lambda
   auto-creates the log group with never-expire retention, and your `aws_cloudwatch_log_group`
   apply then fails with `ResourceAlreadyExistsException`.

2. **`image_uri` must include the tag**, e.g. `...specsage-api:7f808fd`. Terraform accepts a
   bare repo URI at plan time and fails at apply.

3. **`architectures` is a list**: `["arm64"]`, not `"arm64"`.

4. **Function URL format.** The output is `https://xxx.lambda-url.us-east-1.on.aws/` with a
   scheme and trailing slash. The data layer strips both — read `local.lambda_origin_domain`
   in `infra/data/cloudfront.tf` so your output shape matches what it expects.

---

## Phase 4 — Prove the code matches the console (10 min)

Delete the console-built function, function URL, role, and log group by hand. Then:

```bash
cd infra/compute
terraform init
terraform plan -out=tfplan     # expect ~5 to add, 0 to destroy
terraform apply tfplan
curl -s $(terraform output -raw function_url)health | python3 -m json.tool
```

Same response as Phase 2 means the code is the source of truth. If anything differs, the
console set a default you did not encode — find it and add it.

---

## Phase 5 — Close the loop (5 min)

Point CloudFront at Lambda:

```bash
cd ../data
terraform apply -var="lambda_function_url=$(cd ../compute && terraform output -raw function_url)"
```

CloudFront takes ~3 min. Then the M0 release checkpoint:

```bash
curl -s https://d3dxlxj4unjdgm.cloudfront.net/health | python3 -m json.tool
```

`git_sha` must equal `git rev-parse --short HEAD`. **That is M0 done.**

### Then harden the Function URL

Switch `authorization_type` to `AWS_IAM`, add an `aws_cloudfront_origin_access_control` with
`origin_access_control_origin_type = "lambda"`, attach it to the Lambda origin, and add a
`aws_lambda_permission` allowing `cloudfront.amazonaws.com` to invoke with a `SourceArn`
condition scoping it to your distribution.

Verify the property: direct Function URL call returns **403**, CloudFront still returns **200**.
Same test that proved OAC on the web bucket.

---

## How I will review

| Check | Looking for |
|---|---|
| Least privilege | Execution role has Logs only. No Bedrock, no S3 "for later". |
| Log retention | Explicit, with `depends_on` ordering |
| Immutability | `image_tag` required, no `latest` default |
| Layer boundary | No `data`-layer resources; consumes nothing but its own state |
| Guard rails | `allowed_account_ids`, `default_tags` with `Layer = "compute"` |
| Naming | Patterns from `docs/PATTERNS.md` named in comments where applied |
| Destroyability | `terraform destroy` leaves zero billable resources — this layer is destroyed nightly |

That last row is the one that matters most. This layer is disposable by design; anything in it
that survives a destroy is a bug.

---

## Cost

Free tier: 1M requests + 400,000 GB-seconds/month, perpetual. At 1024 MB, a 100 ms request is
0.1 GB-s — roughly **4 million requests/month before you pay anything**. Idle is genuinely $0;
Lambda bills only while executing.

Log storage is the real cost, which is why 7-day retention is Phase 2b rather than an
afterthought.
