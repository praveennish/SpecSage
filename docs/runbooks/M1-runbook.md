# M1 Runbook — Data Acquisition

Operational guide for the M1 ingestion pipeline: bring it up from a clean checkout, run a
corpus fetch, verify the result, re-run, and recover from the failure modes that actually
happen.

- **Console walkthrough** (what each resource is, where it lives in the UI):
  [`M1-ingestion-console.md`](./M1-ingestion-console.md)
- **Architecture diagram:** [`../diagrams/M1-architecture.png`](../diagrams/M1-architecture.png)
  (source: [`../diagrams/M1-architecture.dot`](../diagrams/M1-architecture.dot))
- **Master runbook** (account setup, layers, daily stop/start): [`../RUNBOOK.md`](../RUNBOOK.md)

---

## 0. What M1 delivers

Corpus acquisition as a one-off **ECS Fargate** task that fetches openly-licensed
computer-architecture documents and writes them to
`s3://specsage-artifacts-941500193593/raw/`, with a **build-failing licence gate** in front
of every download.

**Release checkpoint:** trigger the Fargate task and confirm raw documents plus a fully
populated `raw/manifest.yaml` land in S3. Parsing, chunking and embedding are M2+.

Current registry ([`ingestion/sources.py`](../../ingestion/sources.py)): `riscv-isa-manual`,
`devicetree-spec`, `linux-arm64-docs`, `linux-x86-docs`, `bcm2711-peripherals` — three
structural types (ISA spec, kernel doc, datasheet; arXiv paper deferred). RISC-V is the only
full ISA spec; ARM64 and x86 are kernel/systems docs (GPL-2.0, copyleft — see
[D-029](../DECISION-LOG.md)). `PAGE_CEILING = 1500` (PDF pages only; the ~73 `.rst` files
don't count). Dry-run total: ~76 files, ~7.6 MB.

---

## 1. Prerequisites

| Need | Check |
|---|---|
| Toolchain: `uv`, Terraform ≥ 1.10, Docker, AWS CLI v2 | `make verify-setup` |
| `[specsage]` credentials profile → account `941500193593` | `make check-aws` |
| Environment loaded into the shell | see below |
| `data` layer applied (owns the artifacts bucket + ECR repo) | `terraform -chdir=infra/data output` |

### 1.1 Load the environment

The Makefile does **not** read any dotenv file — it reads exported shell variables. Load
`.env.local` yourself at the start of every session:

```bash
cp .env.local.example .env.local     # first time only; then fill in
set -a && source .env.local && set +a
```

`.env.local` must define at least:

```bash
SPECSAGE_ACCOUNT_ID=941500193593     # asserted by every AWS-touching Make target
AWS_PROFILE=specsage
AWS_REGION=us-east-1
TF_VAR_aws_account_id=941500193593   # consumed by every Terraform stack, any directory
```

> **Why `TF_VAR_aws_account_id` and not a `terraform.tfvars`.** Each stack auto-loads
> `terraform.tfvars` only from its own directory, so a file in `infra/bootstrap/` does
> nothing for `infra/compute/`. `TF_VAR_*` is read by every `terraform` invocation
> regardless of `-chdir`, and it is the same mechanism CI uses. `aws_account_id` has no
> default (the provider's `allowed_account_ids` guard depends on it), so it must be supplied
> one way or the other.

---

## 2. First bring-up

M1's infrastructure lives in the **`compute`** layer alongside the Lambda. `make up` applies
that layer but never builds a container image, and the ECS task and the Lambda both run
`FROM specsage-api:<git-sha>` — so the image for the commit you are on must already be in
ECR.

### 2.1 Initialise each stack (once per machine)

`terraform init` writes a gitignored `.terraform/` directory; a fresh clone has none.

```bash
terraform -chdir=infra/data    init
terraform -chdir=infra/compute init
```

If `infra/bootstrap` has never been applied in this account, do that first — see
[`../RUNBOOK.md` §5](../RUNBOOK.md). Its state is in S3
(`s3://specsage-tfstate-941500193593/`); a plain `terraform -chdir=infra/bootstrap init`
picks it up.

### 2.2 Make sure an image exists

```bash
aws ecr list-images --repository-name specsage-api \
  --query 'imageIds[].imageTag' --output text
```

- **Your commit's short SHA is listed** → continue to 2.3.
- **It is not** → build and push it. With Docker working locally:

  ```bash
  make deploy      # build linux/arm64 -> push -> apply compute -> smoke
  ```

  Without local Docker access, run the **Deploy** GitHub Action (Repo → Actions → Deploy →
  environment `dev`), which builds and pushes on the runner. Or, to bring the stack up
  against an already-built commit, override the tag for this session:

  ```bash
  make up GIT_SHA=<an-existing-tag>
  ```

  The image bakes its own `GIT_SHA`, and `make up`'s smoke test asserts `/health`'s
  `git_sha` equals the tag it deployed, so the override must name a tag that is really in
  ECR.

### 2.3 Apply

```bash
make up                       # or: make up GIT_SHA=<existing-tag>
```

`make up` applies `compute`, reads the Lambda Function URL, re-applies `data` with it to
point CloudFront at Lambda, waits for the distribution, and smoke-tests. The M1 resources
(ECS cluster, task definition, task/execution/EventBridge roles, log group, EventBridge
rule) come up as part of the `compute` apply.

Confirm the plan is clean afterwards:

```bash
terraform -chdir=infra/compute plan   # expect: No changes.
```

---

## 3. Run an ingestion

```bash
make ingest
```

The target reads `subnet_ids`, `task_security_group_id`, `ecs_cluster` and
`ingestion_task_definition` from `compute` outputs, calls `aws ecs run-task` with
`assignPublicIp=ENABLED`, waits for the task to stop, prints the CloudWatch logs, and
**exits non-zero if the container did**.

> Use the Make target, not a hand-assembled `aws ecs run-task`. The CLI shorthand parser
> rejects newlines and spaces inside `awsvpcConfiguration={...}`, so the readable multi-line
> form does not work — the call has to be one line, which is why it lives in a tested target.

To run it from the console instead, follow
[`M1-ingestion-console.md` Part 4](./M1-ingestion-console.md) — the one setting that bites is
**Public IP: Turned on**, which defaults to off in the Run-task dialog.

### Expected log sequence

```
licence preflight passed for 5 source(s)
fetched riscv-isa-manual/riscv-spec.pdf (5542xxx bytes, ~906 pages)
fetched devicetree-spec/devicetree-specification-v0.4.pdf (422295 bytes, 64 pages)
fetched linux-arm64-docs/... (27 files)
fetched linux-x86-docs/... (46 files, incl. nested x86_64/ and i386/)
fetched bcm2711-peripherals/bcm2711-peripherals.pdf (1329416 bytes, ~166 pages)
page ceiling ok: 1136 / 1500
corpus: 76 file(s), 7.6 MB, 1136 pages across 5 source(s)
s3://specsage-artifacts-941500193593/raw/ — 76 uploaded, 0 unchanged, manifest written
```

---

## 4. Verify

```bash
aws s3 ls s3://specsage-artifacts-941500193593/raw/ --recursive --human-readable --summarize
aws s3 cp s3://specsage-artifacts-941500193593/raw/manifest.yaml - | head -40
```

Checklist:

- [ ] One prefix per source under `raw/`, plus `raw/manifest.yaml`.
- [ ] Every manifest entry has `licence`, `licence_url`, `sha256`, `size_bytes`, `s3_key`.
- [ ] `doc_type` covers `isa_spec`, `kernel_doc`, `datasheet`.
- [ ] Licence gate is green locally: `uv run pytest tests/ingestion/`.
- [ ] `docs/PROVENANCE.md` reflects the manifest (mirrored and committed by hand).

### Re-run semantics

Run `make ingest` a second time — it should report **`0 uploaded, N unchanged`**. Each
object carries its SHA-256 as user metadata and an upload is skipped when the remote hash
matches, so a no-op run creates zero new S3 object versions. Any new version in the bucket
therefore means an upstream document genuinely changed. That signal is the point of pinning
`release_tag` / `ref` in `sources.py`.

---

## 5. The schedule

The EventBridge rule `specsage-ingestion` is created **DISABLED** ([`infra/compute/ecs.tf`](../../infra/compute/ecs.tf)).
On-demand is enough for M1; a stale corpus only matters at M12. The wiring exists so enabling
it later is a one-line change (`state = "ENABLED"`), not new infrastructure.

```bash
aws events enable-rule --name specsage-ingestion     # by hand, temporary
```

---

## 6. Adding or changing a source

One place, one row: [`ingestion/sources.py`](../../ingestion/sources.py). A document cannot
enter the corpus without naming a `licence`, and `assert_redistributable()` runs in the
preflight before any bytes are fetched.

1. Add a `Source(...)` and append it to the `SOURCES` list.
2. Pin it — `release_tag` for a GitHub release asset, `ref` (a tag or SHA) for a GitHub
   tree. Unpinned means "track upstream", which silently rots the M7 golden set.
3. `uv run pytest tests/ingestion/` — the licence tests fail the build if the licence does
   not resolve to the allow-list, or if an `index_only` source is marked `full_text`.
4. Watch `PAGE_CEILING`. A source five times larger than its `est_pages` would inflate M3
   embedding and M4 per-chunk LLM spend; the job halts instead.
5. `make ingest`, verify, then mirror `docs/PROVENANCE.md` and record the rationale in
   `docs/DECISION-LOG.md`.

> The source list is **Praveen's call** (build brief; M1 plan §6). The current selection
> rationale and the verified-redistributable-only policy are recorded at the top of
> `sources.py` and in `DECISION-LOG.md`.

---

## 7. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `SPECSAGE_ACCOUNT_ID is not set` | `.env.local` not sourced into the shell | `set -a && source .env.local && set +a` |
| `No value for required variable "aws_account_id"` | `terraform.tfvars` is in the wrong stack dir, or missing | Add `TF_VAR_aws_account_id=941500193593` to `.env.local` (§1.1) |
| `terraform init should be run first` | fresh clone, no local `.terraform/` | `terraform -chdir=infra/<stack> init` (§2.1) |
| `Source image ... :<sha> does not exist` on `CreateFunction` | no image in ECR for this commit | build/push, or `make up GIT_SHA=<existing-tag>` (§2.2) |
| `statement id (FunctionURLAllowPublicAccess) already exists` (409) | resource created in AWS but absent from TF state (interrupted / retried apply) | `terraform -chdir=infra/compute import aws_lambda_permission.url_invoke_url specsage-api/FunctionURLAllowPublicAccess`, then re-plan |
| `CannotPullContainerError` | task has no route out — Public IP off, no NAT | run via `make ingest`, or turn Public IP on in the console Run-task dialog |
| `exec format error` / task exits instantly | task definition architecture ≠ image (`X86_64` vs `arm64`) | task def OS/Architecture = **Linux/ARM64** |
| Task starts then `AccessDenied` on S3 | S3 policy put on the *execution* role instead of the *task* role | the container uses `specsage-ingestion-task`; keep S3 there |
| Image pull times out though Public IP is on | VPC DNS hostnames disabled | enable DNS hostnames on the VPC |
| Job halts: `corpus is N pages, ceiling is 1500` | an upstream doc grew, or too many sources added | trim `sources.py`, or raise `PAGE_CEILING` knowing the M3/M4 cost |
| `licence preflight failed` | a source lacks a resolvable licence | working as designed — nothing was downloaded; fix the `Source` row |

---

## 8. Cost

| Resource | Billing | $/mo |
|---|---|---|
| VPC / subnets / IGW / route table / SG | free | 0.00 |
| ECS cluster (a namespace) | free | 0.00 |
| EventBridge rule | free tier | 0.00 |
| CloudWatch Logs, 7-day retention | per GB | ~0.05 |
| S3 storage (~7 MB corpus) | per GB | ~0.01 |
| **Fargate task** | **per second running** | **~$0.0002 / ~20 s run** |
| **Total M1 delta** | | **~$0.06/mo + ~$0.0002/run** |

No NAT Gateway ([D-007](../DECISION-LOG.md)) — that single omission saves ~$65/mo versus the
console VPC wizard's default. Keep `docs/COSTS.md` current when infra changes.
