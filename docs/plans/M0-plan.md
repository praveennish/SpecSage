# M0 Plan — Repo, Docs, CI/CD, and "Hello World" Live on AWS

**Status:** v4 — **approved 2026-07-30**. Scaffolding in progress.
**Decisions:** all reasoning lives in [/docs/DECISION-LOG.md](../DECISION-LOG.md); this plan
references decision IDs rather than restating them.

---

## 1. Goal

Prove the deployment pipeline and the docs discipline work end-to-end before any product logic
exists. Success = `https://<dist-id>.cloudfront.net/health` returns 200 over valid TLS with the
correct git SHA, reached through a pipeline that started from a PR.

Non-goals: any ingestion, embedding, graph, agent, or retrieval logic. Empty packages with
purpose docstrings only.

---

## 2. Architecture (v4)

```
https://<dist-id>.cloudfront.net     free AWS-managed TLS    [D-010]
            │
      CloudFront (persistent, $0 idle)
            │
      Lambda Function URL → container image → FastAPI   [D-019]
```

No ALB, no always-on ECS service, no NAT Gateway, no domain. Fargate returns at M1 for batch
pipeline stages ([D-020](../DECISION-LOG.md#d-020--batch-pipeline-stages-stay-on-fargate--step-functions)).

---

## 3. Repo layout

```
pyproject.toml            Python 3.12 via uv, ruff, pytest
Makefile                  install / lint / test / run-local / up / down / deploy / smoke / verify-empty
.pre-commit-config.yaml   ruff, ruff-format, terraform fmt, detect-secrets
Dockerfile                python:3.12-slim + Lambda Web Adapter, non-root
.gitignore .dockerignore README.md

service/        __init__ main settings version      FastAPI layer
ingestion/ embedding/ graph/ retrieval/ agents/     empty, docstring names the milestone
eval/ mcp_server/ finetune/
frontend/       paused.html                         CloudFront error-page origin; reused at M10

infra/
  bootstrap/                 one-time by hand: TF state bucket, OIDC provider, CI roles, budget
  modules/{data,compute}/    the two managed layers
  environments/dev/
  environments/prod/         placeholder until M12

tests/
  service/test_health.py
  test_repo_layout.py
  smoke/test_live_health.py
  conftest.py

.github/workflows/{ci.yml,deploy.yml}
docs/  (already written)
```

---

## 4. Terraform layers

| Layer | Lifecycle | Contents |
|---|---|---|
| `bootstrap` | never destroyed, applied by hand | state bucket, OIDC provider, `gha-plan` + `gha-deploy` roles, AWS Budget |
| `data` | never destroyed | S3 (state-adjacent buckets, corpus, snapshots, eval site, paused page), ECR, CloudFront |
| `compute` | `make up` / `make down` | Lambda function + Function URL, IAM execution role, log group |

Per [D-013](../DECISION-LOG.md#d-013--infra-split-into-three-lifecycle-layers). CloudFront lives
in `data` because it costs nothing idle and is slow to destroy; `make up` updates its origin to
the current Lambda Function URL.

Provider guardrail ([D-015](../DECISION-LOG.md#d-015--allowed_account_ids-provider-guardrail)):

```hcl
provider "aws" {
  region              = "us-east-1"
  profile             = "specsage"
  allowed_account_ids = [var.aws_account_id]
  default_tags { tags = { Project = "SpecSage", ManagedBy = "terraform" } }
}
```

---

## 5. Cost

| State | $/mo |
|---|---|
| Idle | **~$1.30** |
| Active | **~$1.30** — Lambda and CloudFront free tiers cover demo traffic |

Full breakdown in [/docs/COSTS.md](../COSTS.md). M0's delta is the entire persistent layer, and
it already clears M12's idle target by an order of magnitude.

---

## 6. CI/CD

**`ci.yml` — on pull_request** (fully automatic, needs no cloud):
1. `uv sync` → `ruff check` + `ruff format --check`
2. `pytest -m "not smoke and not integration"` with a coverage gate
3. `terraform fmt -check` + `validate` + `plan` for each layer, plan posted as a PR comment
4. `docker build` (no push) to catch Dockerfile breakage in review

**`deploy.yml` — `workflow_dispatch`** ([D-018](../DECISION-LOG.md#d-018--deploys-are-workflow_dispatch-pr-checks-stay-automatic)):
1. Build image, tag with git SHA + `latest`, push to ECR
2. `terraform apply` on the selected layer — GitHub Environment approval gate
3. Update the Lambda function code, wait for the update to settle
4. **Smoke test** asserting `/health` returns 200 *and* `git_sha == github.sha`. Fails the
   deploy on mismatch — the check that catches "apply succeeded, stale code still serving"

Auth is GitHub OIDC ([D-009](../DECISION-LOG.md#d-009--cicd-auth-github-oidc-no-long-lived-aws-access-keys)).

---

## 7. Tests

| Test | Type | Asserts |
|---|---|---|
| `test_health_200` | unit | 200 + JSON shape |
| `test_health_reports_git_sha` | unit | SHA read from env; missing → `"unknown"`, not a crash |
| `test_health_leaks_no_secrets` | unit | body matches no secret-shaped pattern |
| `test_repo_layout` | structural | every package has an `__init__.py` with a non-empty docstring |
| `test_live_health` | smoke | live CloudFront URL 200 over TLS + SHA matches the deployed commit |

Markers: `unit` (default), `integration`, `smoke`. `make test` runs unit only.

---

## 8. Execution order

1. ✅ Docs written — `DECISION-LOG`, `ARCHITECTURE`, `DECISIONS`, `COSTS`, `RUNBOOK`,
   `PROVENANCE`, `INTERVIEW-NOTES`, `diagrams/architecture.mermaid`
2. **▶ In progress:** scaffolding — `pyproject.toml`, `Makefile`, pre-commit, packages
3. FastAPI `/health` + Dockerfile + unit tests; verify `make run-local` and `make test`
4. `infra/bootstrap` — **you apply this by hand** once §1 of the runbook is done
5. `infra/modules/*` + `infra/environments/dev`
6. **STOP** — real `terraform plan` output + final cost number posted for approval
7. First apply; confirm `/health` live over HTTPS
8. `.github/workflows/*`, proven via a throwaway PR that bumps the version string
9. Docs refresh; flag which ADRs you should write

Steps 2–3 need no AWS and are running now, in parallel with your §1 runbook tasks.

---

## 9. Blocked on you

[RUNBOOK §1](../RUNBOOK.md#1-first-time-aws-setup--owner-tasks). Summary:

- [ ] Confirm the existing personal account is sole-access; MFA on root
- [ ] IAM user `specsage-admin` → access key → `[specsage]` profile (raw values, no quotes)
- [ ] **Bedrock model access in us-east-1** — request now, it can queue
- [ ] Activate the `Project` cost-allocation tag (not retroactive — before first apply)
- [ ] AWS Budget with an email alert
- [ ] Send me the 12-digit account ID

No domain. No GPU quota request. No CI IAM user.

---

## 10. Yours to decide

Nothing structural in M0 — it's plumbing, and §2 of the brief says to drive it fully. What is
yours: the **ADR entries** in [DECISIONS.md](../DECISIONS.md). Four from M0 earn a slot —
no-NAT (D-007), OIDC-over-keys (D-009), the three-layer lifecycle (D-013/D-017), and the
Lambda-over-Fargate revision (D-019). I've queued them there; I won't write them.
