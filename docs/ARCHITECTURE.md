# SpecSage — Architecture

**Living document.** Updated at the end of every milestone to reflect what actually exists,
not what is planned. Decisions and their reasoning live in
[DECISION-LOG.md](./DECISION-LOG.md); owner-authored ADRs live in [DECISIONS.md](./DECISIONS.md).

**Status:** M0 in progress. `bootstrap` and `data` layers are **live**.
Public URL: **https://d3dxlxj4unjdgm.cloudfront.net** (serving the paused page — `compute` not
yet built).

---

## 1. What SpecSage is

An agentic RAG + knowledge-graph system over openly-licensed computer-architecture
documentation (RISC-V ISA specs, OpenTitan, Zephyr, Devicetree, Linux kernel arm64 docs, open
SoC datasheets, arXiv papers). It answers questions with verifiable citations, traces
cross-references that pure vector search cannot follow, and exposes itself as an MCP server so
any Claude client can query it directly.

The differentiating pieces are the **evaluation harness** (M7) and the **teacher/student
cascade** (M9) — a distilled open-weight model serving the cheap path with automatic fallback
to Claude on low confidence or failed citation verification.

---

## 2. Current state (M0)

Deployed and verified in account `941500193593`:

```
  Browser ──▶ https://d3dxlxj4unjdgm.cloudfront.net   [LIVE, valid TLS]
                          │
              CloudFront E38H2SZ7YVFENH               [data layer]
                          │
                 ┌────────┴────────┐
                 │                 │
         (no lambda origin)   S3 web bucket           [OAC — 403 direct, 200 via CDN]
                 │                 │
          compute not built    paused.html            [200 on / and /health]
```

| Layer | Resources | Status |
|---|---|---|
| `bootstrap` | state bucket, OIDC provider, 2 CI roles, budget | ✅ applied |
| `data` | artifacts + web buckets, ECR, CloudFront, OAC | ✅ applied |
| `compute` | Lambda container + Function URL | ⬜ not built |
| CI/CD | `ci.yml`, `deploy.yml` | ⬜ not built |

Once `compute` exists, `make up` sets `lambda_function_url` on the `data` layer and CloudFront
re-points its default behaviour at Lambda. Everything else in this document is the target
shape, built milestone by milestone.

---

## 3. Target architecture

### 3.1 Request path

```
  Browser ──▶ CloudFront ──▶ Lambda (FastAPI) ──▶ retrieval library
                  │                                    │
                  │                          ┌─────────┼─────────┐
                  │                          ▼         ▼         ▼
                  │                     Qdrant     Neo4j     Bedrock
                  │                     Cloud      AuraDB    (Titan / Claude)
                  │                                              │
                  └── S3 static "paused" page              Modal (student model)
```

### 3.2 Pipeline path

```
  EventBridge / manual
        │
        ▼
  Step Functions
        │
        ├─▶ Fargate: ingest      (M1) ──▶ s3://…/raw/
        ├─▶ Fargate: parse+chunk (M2) ──▶ s3://…/processed/chunks.jsonl
        ├─▶ Fargate: embed       (M3) ──▶ Qdrant Cloud
        └─▶ Fargate: graph       (M4) ──▶ Neo4j AuraDB
```

Two compute models by design: **Lambda for request/response**, **Fargate for batch**. The split
is by workload shape — sub-second stateless calls vs multi-minute memory-hungry jobs — not by
preference. See [D-019](./DECISION-LOG.md#d-019--requestresponse-api-on-lambda-not-an-always-on-ecs-service)
and [D-020](./DECISION-LOG.md#d-020--batch-pipeline-stages-stay-on-fargate--step-functions).

---

## 4. Infrastructure lifecycle layers

The single most consequential structural decision
([D-013](./DECISION-LOG.md#d-013--infra-split-into-three-lifecycle-layers)). Terraform is split
by *how long a thing must live*, not by what it is.

| Layer | Lifecycle | Contents | Idle cost |
|---|---|---|---|
| `bootstrap` | Never destroyed. Applied once, by hand. | TF state bucket, GitHub OIDC provider, CI IAM roles | ~$0.05/mo |
| `data` | Never destroyed. | S3 (raw / processed / snapshots / eval site), ECR, CloudFront | ~$1/mo |
| `compute` | Destroyed between work sessions. | VPC, Lambda, Fargate task definitions, Step Functions | $0 |

`make up` / `make down` operate on `compute` only. `make down` snapshots stateful services into
`data` before destroying; `make up` restores from the latest snapshot rather than rebuilding
from scratch.

**Why this matters beyond cost:** a stack that is destroyed nightly cannot accumulate
undocumented state. Every artifact must be reconstructible from S3 or git, or it does not
survive to the next session.

### What must never be destroyed

| Artifact | From | Rebuild cost | Lives in |
|---|---|---|---|
| Raw corpus | M1 | Slow; sources rate-limit or move | `data` (S3) |
| `chunks.jsonl` | M2 | Cheap compute | `data` (S3) |
| Qdrant index | M3 | Embedding calls + tens of minutes | snapshot → `data` |
| Neo4j graph | M4 | **One LLM call per chunk** | export → `data` |
| `golden_qa.jsonl` | M7 | **Irreproducible** — hand-curated | **git** |
| QLoRA adapter | M9 | A GPU run | `data` + HuggingFace |

---

## 5. Repository layout

```
service/        FastAPI HTTP layer — thin; imports the libraries below
ingestion/      M1 — corpus acquisition + licence manifest
embedding/      M3 — Bedrock Titan embeddings → Qdrant
graph/          M4 — two-pass reference extraction → Neo4j
retrieval/      M5 — vector + graph hybrid search. Zero agent-framework dependency.
agents/         M6 — AgentTool protocol + LangGraph implementation
eval/           M7 — golden set curation CLI + scoring harness
mcp_server/     M8 — MCP tool surface
finetune/       M9 — distillation dataset build + QLoRA training
frontend/       M10 — single-page chat UI
infra/          bootstrap / modules / environments
tests/          mirrors the source tree
docs/           this directory
```

### Enforced boundaries

- **`retrieval/` imports no agent framework.** Enforced by an import-linter rule in CI so it
  cannot regress silently. Orchestration is swappable; retrieval is the stable backbone.
- **`agents/interfaces.py` defines the contract; LangGraph is an implementation detail.**
- **Every package `__init__.py` carries a docstring** naming the milestone that fills it. A
  structural test fails the build if one is empty.

---

## 6. Security posture

| Concern | Control |
|---|---|
| Wrong-account apply | `allowed_account_ids` on the AWS provider — fails at plan time, not apply time |
| Credential separation | Personal creds on the `[specsage]` profile; corporate SSO keeps `[default]` |
| CI credentials | GitHub OIDC; no static AWS keys in GitHub secrets |
| Inbound network path | No public ingress to compute; security groups accept only front-door traffic |
| Secrets | Secrets Manager, read by task/function role only. Never in git, never in the browser |
| Licence compliance | Build fails if any `manifest.yaml` entry lacks a resolvable licence |
| Arm ARM isolation (M11) | Terraform refuses to apply if the private instance would get public ingress |

No NAT Gateway ([D-007](./DECISION-LOG.md#d-007--no-nat-gateway-workloads-in-public-subnets-with-sg-restricted-ingress)):
the property that matters is *no inbound path from the internet*, which a security group
delivers as effectively as a private subnet, for $33/mo less. Revisited at M10 and M12.

---

## 7. Model usage

| Stage | Model ID | Status | Why |
|---|---|---|---|
| M3 embeddings | `amazon.titan-embed-text-v2:0` | ✅ verified, 1024 dims | Pennies at this corpus size |
| M4 graph extraction | `us.anthropic.claude-haiku-4-5-20251001-v1:0` | ✅ verified | Structured extraction under a quoted-source constraint |
| M7 LLM-as-judge | `us.anthropic.claude-haiku-4-5-20251001-v1:0` | ✅ verified | Disagreement rate is measured, so weakness is detectable |
| M6 synthesis (teacher) | `us.anthropic.claude-sonnet-4-6` | ✅ verified | Quality *is* the product — M9 distils its citation formatting. Not a placeholder for Sonnet 5; see D-028. |
| M9 student | Qwen2.5-7B-Instruct + QLoRA | — | Apache 2.0 keeps the public artifact licence-clean |

**Claude models take the `us.` cross-region inference-profile prefix; Titan takes the bare
ID.** The bare `anthropic.claude-…` form is rejected for on-demand throughput. IDs are pinned
in config after an invocation test, never derived by rule — `ListFoundationModels` returns
models you cannot call, so it is not an access check. Run `make check-bedrock` to re-verify.

**This account has access to Claude 4.6-and-earlier, not the newest release wave.** Sonnet 5,
Opus 5, Opus 4.8, Opus 4.7, and Fable 5 all return `AccessDeniedException`; Haiku 4.5, Sonnet
4.6, Sonnet 4.5, Opus 4.6, Opus 4.5, and Opus 4.1 all work. Sonnet 4.6 is the working teacher —
Sonnet 5 is an opportunistic upgrade to evaluate at M9 if access clears, not a blocker.
See [D-028](./DECISION-LOG.md#d-028--bedrock-access-via-anthropicbedrockmantle-model-ids-verified).

Accessed via `AnthropicBedrockMantle` (the Messages-API Bedrock endpoint), not the legacy
`InvokeModel` path. Manual `cache_control` breakpoints on repeated instruction prefixes —
automatic prompt caching is not available on Bedrock.

---

## 8. What is deliberately *not* here

Stating these prevents them being read as oversights:

- **No NAT Gateway** — see §6.
- **No always-on service** — the API is Lambda; batch is per-second Fargate.
- **No self-hosted vector database** — Qdrant Cloud's free tier removes a stateful service for
  $0. Operating a vector DB is not a stated learning goal; using one well is.
- **No EC2 GPU** — training runs on Modal/Kaggle free tiers, which also removes the
  multi-day G-instance quota request from the critical path.
- **No custom domain** — CloudFront's default certificate supplies valid TLS for free. Adding a
  domain later is one certificate, one alias, one DNS record.
- **No fine-tuned router** — a 3-class problem does not justify it. The right-sizing judgement
  is itself a deliverable.

---

## 9. Milestone map

| M | Delivers | Key infra added |
|---|---|---|
| M0 | `/health` live, CI/CD, docs discipline | CloudFront, Lambda, ECR, S3, OIDC |
| M1 | Corpus + licence manifest in S3 | Fargate task, EventBridge |
| M2 | Section-aware chunks | Step Functions chain |
| M3 | `POST /search` | Qdrant Cloud, Bedrock Titan |
| M4 | `POST /trace` | Neo4j AuraDB |
| M5 | `POST /hybrid_search` | CloudWatch metrics |
| M6 | `POST /answer` | LangGraph agents, router |
| M7 | Public eval report | Scheduled eval task, S3 static site |
| M8 | Live MCP endpoint | MCP service |
| M9 | Teacher/student cascade | Modal GPU, HuggingFace |
| M10 | Public website | WAF, API Gateway, rate limits, cost circuit breaker |
| M11 | Private Arm instance *(optional)* | Isolated deployment + apply guardrail |
| M12 | Prod environment | Prod stack, alarms, scale-to-zero |
| M13 | Interview packaging | — |
