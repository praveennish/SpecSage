# SpecSage — Design Pattern Catalogue

Every recognised pattern used in this codebase: where it is applied, why that pattern rather
than another, and what skipping it would have cost.

**Rule for this file:** no pattern theatre. If something is just a function, it is not listed
here. A pattern named is a pattern that can be challenged as the wrong choice — that is the
point of writing it down.

**Status:** M0. Grows each milestone.

---

## Index

| # | Pattern | Where | Milestone |
|---|---|---|---|
| P-01 | Ports and Adapters (Hexagonal Architecture) | `retrieval/` ← `service/`, `agents/`, `mcp_server/` | M0 → M8 |
| P-02 | Dependency Inversion via Protocol | `agents/interfaces.py` | M6 |
| P-03 | Sidecar | Lambda Web Adapter in `Dockerfile` | M0 |
| P-04 | Immutable Infrastructure | SHA-tagged images, no in-place edits | M0 |
| P-05 | Fail-Fast Guard Clause | `allowed_account_ids`, `make check-aws` | M0 |
| P-06 | Bulkhead (lifecycle stratification) | `infra/bootstrap` / `data` / `compute` | M0 |
| P-07 | Externalised Configuration (12-Factor III) | `service/settings.py` | M0 |
| P-08 | Federated Short-Lived Credentials | GitHub OIDC → IAM role | M0 |
| P-09 | Versioned Artifact + Alias Rollback | Lambda published versions + `live` alias | M0 |
| P-10 | Build-Time Provenance Stamping | `GIT_SHA` build arg → `/health` | M0 |
| P-11 | Pipes and Filters | Step Functions batch chain | M1–M4 |
| P-12 | Snapshot / Restore (state externalisation) | `make down` / `make up` | M0 → M3 |
| P-13 | Circuit Breaker | Cost kill switch | M10 |
| P-14 | Cascade with Fallback | Teacher/student synthesis | M9 |
| P-15 | Strategy | Router → retrieval / graph / hybrid path | M6 |

---

## P-01 — Ports and Adapters (Hexagonal Architecture)

**Where.** `retrieval/` is the domain core. `service/` (HTTP), `mcp_server/` (MCP protocol),
`eval/` (test harness), and `agents/` (orchestration) are all adapters that call into it. The
boundary is enforced mechanically by an import-linter contract in `pyproject.toml`:

```toml
[[tool.importlinter.contracts]]
name = "retrieval must not depend on any agent framework"
type = "forbidden"
source_modules = ["retrieval"]
forbidden_modules = ["agents", "langgraph", "langchain"]
```

**Why this pattern.** The same retrieval logic must be reachable from four transports that have
nothing in common: HTTP requests, the MCP protocol, a batch eval harness, and an agent
framework's tool-call loop. Any design where retrieval knows about its caller forces three of
those four to route through the wrong abstraction. Hexagonal inverts it — retrieval knows
nothing, and each caller adapts.

**Why not layered/N-tier.** A conventional layering (controller → service → repository) assumes
one primary entry point with the others bolted on. Here there genuinely isn't one; MCP is as
first-class as HTTP.

**Cost of skipping.** LangGraph would end up imported inside retrieval within about two
milestones — the pull is real, because it is momentarily convenient. At that point the
"swappable orchestration" claim becomes false, and the M8 MCP server has to either duplicate
retrieval logic or drag an agent framework into a protocol server that has no use for one. The
import-linter rule exists because this boundary erodes silently rather than loudly.

---

## P-02 — Dependency Inversion via Protocol

**Where.** `agents/interfaces.py` defines an `AgentTool` protocol. LangGraph implements it;
nothing depends on LangGraph's own types.

**Why this pattern.** Agent frameworks are the fastest-moving layer in this stack. Depending on
a `structural` protocol (Python `typing.Protocol`) rather than a base class means an
implementation does not even need to import our module to satisfy the contract.

**Why Protocol rather than ABC.** An ABC requires the implementer to inherit, which means
importing our package — a compile-time coupling in the wrong direction. `Protocol` is
structural: conformance is checked at the type-check boundary, not at import time.

**Cost of skipping.** Swapping to Bedrock Agents at M12 would touch retrieval and eval code
rather than just orchestration.

---

## P-03 — Sidecar

**Where.** `Dockerfile` copies the AWS Lambda Web Adapter into `/opt/extensions/`. It runs
beside the application process and translates Lambda's invocation model into ordinary HTTP.

```dockerfile
COPY --from=public.ecr.aws/awsguru/aws-lambda-adapter:0.8.4 \
     /lambda-adapter /opt/extensions/lambda-adapter
```

**Why this pattern.** The alternative is an in-process handler shim (Mangum or similar), which
puts Lambda-awareness *inside* the application. The sidecar keeps the deployment target out of
the codebase entirely: `service/main.py` contains no Lambda import, no handler function, and no
conditional on execution environment.

**The property this buys.** The image runs identically under `docker run` and under Lambda —
same entrypoint, same uvicorn process, same port. Local behaviour cannot silently diverge from
deployed behaviour, which is the usual failure mode of serverless web frameworks.

**Cost of skipping.** A Mangum-style shim couples the app to Lambda and makes local/deployed
divergence possible. It also makes P-01 harder — the HTTP adapter starts carrying deployment
concerns.

---

## P-04 — Immutable Infrastructure

**Where.** Container images are tagged with the git SHA and never mutated. Deploys publish a
new Lambda version rather than editing a running one. Terraform owns every resource; nothing is
edited in the console.

**Why this pattern.** Rollback becomes "point at the previous artifact" instead of "rebuild and
hope". Combined with P-09, rollback is seconds and requires no build.

**Cost of skipping.** `latest`-tagged deploys make it impossible to answer "what is actually
running right now", which is exactly the question you need answered during an incident.

---

## P-05 — Fail-Fast Guard Clause

**Where.** Two layers, deliberately redundant:

```hcl
provider "aws" {
  profile             = "specsage"
  allowed_account_ids = [var.aws_account_id]   # fails at PLAN time
}
```

```make
check-aws:   # fails before terraform is even invoked
	@actual=$$(aws sts get-caller-identity --query Account --output text); \
	if [ "$$actual" != "$$SPECSAGE_ACCOUNT_ID" ]; then exit 1; fi
```

**Why this pattern.** Two AWS profiles on one laptop — a corporate SSO profile on `default`
and this project on `specsage` — is a live footgun. The guard turns a class of mistake that is
expensive and embarrassing (applying a portfolio project into an employer's account) into an
error message.

**Why at plan time, not apply time.** `allowed_account_ids` is evaluated during provider
configuration, so a wrong-account run fails before Terraform has proposed a single resource.

**Cost of skipping.** A policy note in a README. Notes do not fail builds.

---

## P-06 — Bulkhead (lifecycle stratification)

**Where.** `infra/` splits into three independently-stated layers:

| Layer | Lifecycle | Blast radius of a mistake |
|---|---|---|
| `bootstrap` | never destroyed | catastrophic — holds the state bucket |
| `data` | never destroyed | severe — corpus, snapshots, images |
| `compute` | destroyed nightly | none — rebuilt in two minutes |

**Why this pattern.** A single Terraform state means `terraform destroy` can take the corpus
with it. Separate states mean the destructive operation you run most often (`make down`) is
physically incapable of touching the data you can least afford to lose. That is a bulkhead:
compartmentalising so a flood in one section does not sink the ship.

**Why not workspaces.** Workspaces vary *values* across identical resource sets. These layers
have different resources and different lifecycles — that is a module boundary, not a workspace.

**Cost of skipping.** The M4 knowledge graph costs one LLM call per chunk to rebuild. A single
mis-scoped `destroy` would be dollars and hours, not seconds.

---

## P-07 — Externalised Configuration (12-Factor III)

**Where.** `service/settings.py` — all config from the environment via `pydantic-settings`,
with no defaults for secrets.

**Why this pattern.** The same image must run in local, dev, and prod without a rebuild, which
follows from P-04.

**The specific discipline.** Secrets have **no default value**. A default for a secret is a
secret in git waiting to happen; forcing the environment to supply it turns a silent
misconfiguration into a startup failure.

---

## P-08 — Federated Short-Lived Credentials

**Where.** GitHub Actions assumes an IAM role via OIDC. There are no AWS keys in GitHub secrets.

**Why this pattern.** Static CI keys are the most common credential-leak vector in public
repos, and they cannot be scoped to a branch, an environment, or a workflow. OIDC issues
short-lived credentials bound to `repo:praveennish/SpecSage:*`, so a leaked log line is worth
nothing minutes later.

**Cost of skipping.** A long-lived `AKIA…` key in a public repo's settings, rotated never.

---

## P-09 — Versioned Artifact + Alias Rollback

**Where.** Each deploy publishes a Lambda version; a `live` alias points at the current one.

```bash
aws lambda update-alias --function-name specsage-api \
  --name live --function-version <previous>
```

**Why this pattern.** Rollback is a pointer move — seconds, no build, no registry pull. This is
the serverless equivalent of blue/green, without paying to run two environments.

**Cost of skipping.** Rollback becomes "rebuild the previous commit and redeploy", which is
minutes at best and requires a working build pipeline at exactly the moment something is
already broken.

---

## P-10 — Build-Time Provenance Stamping

**Where.** `GIT_SHA` is a Docker build arg baked into the image and surfaced at `/health`. The
deploy workflow asserts the deployed SHA equals the triggering commit.

**Why this pattern.** A 200 from `/health` proves something is alive, not that it is the thing
you just deployed. The most common silent deploy failure is a successful `apply` in front of a
stale artifact. Comparing provenance catches it; a liveness check cannot.

**Design note.** Absent `GIT_SHA` degrades to `"unknown"` rather than raising. A health
endpoint that 500s because it cannot identify itself is worse than one that admits ignorance —
covered by `test_health_degrades_gracefully_without_git_sha`.

---

## P-11 — Pipes and Filters

**Where.** M1–M4: ingest → parse/chunk → embed → graph, chained by Step Functions, with S3 as
the medium between stages.

**Why this pattern.** Each stage reads a well-defined input from S3 and writes a well-defined
output. Stages are independently runnable, independently testable, and independently
restartable — you can re-run chunking against an existing corpus without re-downloading it.

**Why S3 as the pipe rather than direct hand-off.** Durability at a stage boundary is what
makes the pipeline restartable rather than merely retryable, which matters because M4's LLM
extraction pass is the expensive stage and must never be re-run because M2 was tweaked.

---

## P-12 — Snapshot / Restore (state externalisation)

**Where.** `make down` exports Qdrant and Neo4j to S3 before destroying compute; `make up`
restores rather than rebuilding.

**Why this pattern.** It is what makes P-06's disposable `compute` layer safe. Without it,
"destroy nightly" would mean "re-embed the corpus nightly".

**The second-order benefit.** A system destroyed nightly cannot accumulate undocumented state.
Every artifact must be reconstructible from S3 or git, or it does not survive to the next
session — so the constraint forces a property most systems only discover they lack during an
outage.

---

## P-13 — Circuit Breaker *(M10, not yet built)*

**Where.** Daily LLM-spend metric → SNS → Lambda → flips an SSM Parameter Store feature flag,
disabling the public `/answer` path while leaving `/search` and the API-key-gated MCP endpoint
alive.

**Why this pattern.** A billing alarm notifies. A circuit breaker *acts*. With an anonymous
public endpoint triggering Bedrock spend, the gap between notification and action is measured
in whatever time it takes you to read an email.

**The discipline that makes it real.** It gets tripped manually and verified before it is
trusted. An untested breaker is a comment.

---

## P-14 — Cascade with Fallback *(M9, not yet built)*

**Where.** Synthesis tries the distilled student model first; falls back to the Sonnet teacher
on low confidence or failed citation verification. Every response carries `synthesis_path`
(student/teacher) and the fallback reason.

**Why this pattern.** The student is expected to underperform on out-of-distribution questions.
That is a known limitation, and the cascade is the design *around* it rather than a denial of
it — which is a stronger engineering signal than a benchmark that hides the weakness.

**Observability requirement.** Without `synthesis_path` on every response, you cannot tell
whether the cheap path is actually being used, which is the entire economic justification.

---

## P-15 — Strategy *(M6, not yet built)*

**Where.** The router selects retrieval-only, graph-only, or hybrid; each is an interchangeable
strategy behind one interface.

**Why this pattern.** It keeps the router's *selection* logic separate from the strategies'
*execution* logic, so the classifier can be retrained or replaced without touching retrieval.

**Deliberate non-use of a heavier pattern.** The router is a logistic regression over
embeddings, not a fine-tuned model. A 3-class problem does not justify fine-tuning cost,
latency, or a training pipeline — see
[D-003](./DECISION-LOG.md#d-003--routing-classical-classifier-explicitly-not-a-fine-tuned-llm).
Knowing when not to reach for the expensive tool is itself the deliverable.
