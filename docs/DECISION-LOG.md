# SpecSage — Architecture Decision Log

**Purpose.** A complete, machine-readable trace of every architecture decision made on this
project: what was decided, why, what it replaced, and what pressure caused the change. This
file is the *record*. `/docs/DECISIONS.md` holds the owner-authored ADRs written for interview
defence; this file holds the raw traversal those ADRs are distilled from.

**How to read / feed this to an LLM.** Each decision is a fixed-schema block (`ID`, `Status`,
`Date`, `Milestone`, `Trigger`, `Options`, `Decision`, `Reasoning`, `Rejected`, `Supersedes`,
`Superseded by`, `Cost delta`). Superseded decisions are **kept, not deleted** — the point of
this file is the path, not just the endpoint. Section 2 gives the version arc; Section 3 gives
the decisions; Section 4 gives the open questions still unresolved.

---

## 1. Index

| ID | Decision | Status | Milestone |
|---|---|---|---|
| D-001 | Cloud provider: AWS end-to-end | Active | Pre-M0 (A5) |
| D-002 | Orchestration: LangGraph behind a framework-agnostic `AgentTool` interface | Active | Pre-M0 (A5) |
| D-003 | Routing: classical classifier, explicitly not a fine-tuned LLM | Active | Pre-M0 (A5) |
| D-004 | Fine-tuning scoped to synthesis only, behind a teacher/student cascade | Active | Pre-M0 (A5) |
| D-005 | Public corpus: openly-licensed sources only; Arm ARM private-only | Active | Pre-M0 (A5) |
| D-006 | Terraform state: S3 backend with native lockfile, no DynamoDB table | Active | M0 |
| D-007 | No NAT Gateway; workloads in public subnets with SG-restricted ingress | Active | M0 |
| D-008 | Fargate Spot for non-production workloads | Active | M0 |
| D-009 | CI/CD auth: GitHub OIDC, no long-lived AWS access keys | Active | M0 |
| D-010 | HTTPS via CloudFront's default `*.cloudfront.net` certificate | Active | M0 |
| D-011 | No custom domain registered | Active | M0 |
| D-012 | Multi-project domain reuse: subdomains, never subpaths | Deferred | M0 |
| D-013 | Infra split into three lifecycle layers: bootstrap / data / compute | Active | M0 |
| D-014 | AWS account: personal, end-to-end, no mid-project migration | Active | M0 |
| D-015 | `allowed_account_ids` provider guardrail against wrong-account applies | Active | M0 |
| D-016 | Credential isolation via a named `[specsage]` profile | Active | M0 |
| D-017 | Stop-start operating model with snapshot/restore, not always-on | Active | M0 |
| D-018 | Deploys are `workflow_dispatch`; PR checks stay automatic | Active | M0 |
| D-019 | Request/response API on Lambda, not an always-on ECS service | Active | M0 |
| D-020 | Batch pipeline stages stay on Fargate + Step Functions | Active | M1–M3 |
| D-021 | Vector store: Qdrant Cloud free tier, not self-hosted on Fargate + EFS | Active | M3 |
| D-022 | Fine-tuning compute: Modal / Kaggle free tiers, not EC2 GPU | Active | M9 |
| D-023 | Per-stage model right-sizing across Haiku / Sonnet / Opus | Active | M4, M6, M7, M9 |
| D-024 | Prompt caching on repeated instruction prefixes | Active | M4, M9 |
| D-025 | Batch API discount deferred: needs a Bedrock/first-party split | Open | M9 |
| D-026 | Distilled model published to HuggingFace, not AWS; weights gated pending ToS review | Open | M9 |
| D-027 | Account migration at M10 | **Superseded** by D-014 | M10 |
| D-028 | Bedrock access via `AnthropicBedrockMantle`; model IDs verified against the API | Active | M3, M6 |

**Superseded chains at a glance**

```
HTTPS:        D-010a (ALB HTTPS, impossible)
                → D-010b (ACM cert on a registered domain)
                  → D-010  (CloudFront default cert)          [current]

Domain:       D-011a (register praveennishchal.com)
                → D-011  (register nothing)                   [current]

Lifecycle:    D-013a (single always-on stack)
                → D-013b (persistent / ephemeral, 2 layers)
                  → D-013 (bootstrap / data / compute)        [current]

Account:      D-014a (corp account 275279264324)
                → D-014b (corp for M0–M9, personal at M10)
                  → D-014 (personal end-to-end)               [current]
                     ⇒ D-027 (M10 migration) becomes moot

API compute:  D-019a (ALB + always-on ECS Fargate service)
                → D-019 (Lambda container + Function URL)     [current]
```

---

## 2. Version arc — what changed, and what forced it

Each revision of `/docs/plans/M0-plan.md` was driven by a specific piece of new information,
not by preference. The trigger matters more than the outcome.

| Plan | Trigger | What changed | Net cost effect |
|---|---|---|---|
| **v1** (2026-07-28) | Initial planning against Section B of the build brief | ALB + always-on Fargate, no NAT, OIDC, S3 native lockfile | Est. **$22/mo** |
| **v2** (2026-07-28) | Owner asked whether a domain was needed and flagged the service would not be live all the time | Domain registered for HTTPS; infra split persistent/ephemeral so the ALB could be destroyed between sessions | Idle **$2.65/mo**, 24/7 $21.75 |
| **v3** (2026-07-30) | Owner asked to avoid registering a domain at all | CloudFront's free default TLS cert replaces ACM-on-a-domain; CloudFront becomes the persistent front door — which is also M10's target architecture, so the work isn't throwaway | Idle **$1.06/mo** |
| **v4** (2026-07-30) | Owner said total project cost still mattered | ALB deleted entirely (Lambda replaces it); Qdrant Cloud free tier replaces self-hosted Qdrant; Modal/Kaggle free tiers replace the EC2 GPU; per-stage model right-sizing; three-layer lifecycle so stateful artifacts survive teardown | Idle **~$1/mo**, project total **~$35** |

**The through-line:** three of the four revisions were driven by cost, and each one made the
architecture *simpler* rather than more complex — fewer always-on components, fewer self-hosted
services, fewer things to operate. The one revision that wasn't cost-driven (v3, dropping the
domain) also removed a dependency. This is worth being able to articulate: cost pressure on a
portfolio project acted as a forcing function toward a design that is genuinely easier to
defend, not a degraded one.

**The counter-example, for honesty:** v4's Lambda swap does add a second compute model
(Lambda for request/response, Fargate for batch). That is real added surface area. It is
justified because the two workload shapes genuinely differ — but a reviewer is entitled to
push back on it, and "we run two compute models" is a cost that should be stated, not hidden.

---

## 3. Decisions

### D-001 — Cloud provider: AWS end-to-end

- **Status:** Active · **Date:** pre-project · **Milestone:** Pre-M0 (locked by brief §A5)
- **Trigger:** Owner's background is AWS-native distributed systems; the portfolio artifact
  should demonstrate depth where their experience already is.
- **Decision:** AWS for compute, storage, secrets, observability, and edge. Third-party
  services allowed only where AWS has no free-tier-viable equivalent (see D-021, D-022).
- **Reasoning:** Interview leverage. A system built on the platform the owner already knows
  deeply supports harder follow-up questions than one built on unfamiliar infrastructure.
- **Cost delta:** baseline.

### D-002 — Orchestration: LangGraph behind a framework-agnostic `AgentTool` interface

- **Status:** Active · **Date:** pre-project · **Milestone:** Pre-M0 (A5)
- **Decision:** LangGraph implements agent orchestration, but every consumer talks to an
  `AgentTool` protocol defined in `/agents/interfaces.py`. `/retrieval` has **zero** dependency
  on any agent framework, enforced by an import-linter rule in CI.
- **Reasoning:** Agent frameworks are the fastest-moving layer in this stack. Isolating the
  contract means swapping to Bedrock Agents or Google ADK touches orchestration only — not
  retrieval, not eval. The CI rule exists because this kind of boundary erodes silently.

### D-003 — Routing: classical classifier, explicitly not a fine-tuned LLM

- **Status:** Active · **Date:** pre-project · **Milestone:** Pre-M0 (A5) · **Decided at:** M6
- **Options:** (a) logistic regression over M3 embeddings; (b) cheap few-shot LLM call;
  (c) fine-tuned small model.
- **Decision:** (a) or (b). Explicitly not (c).
- **Reasoning:** A 3-class routing problem does not justify fine-tuning cost, latency, or
  the maintenance burden of a training pipeline. **The right-sizing judgement is itself the
  deliverable** — knowing when *not* to reach for the expensive tool is the signal.
- **Rejected:** (c) — cost and complexity with no expected accuracy gain at this class count.

### D-004 — Fine-tuning scoped to synthesis only, behind a teacher/student cascade

- **Status:** Active · **Date:** pre-project · **Milestone:** Pre-M0 (A5) · **Built at:** M9
- **Decision:** QLoRA-distil a student model that imitates the teacher's **citation-formatted
  output**. Facts always come from retrieval at inference time; the student learns format and
  behaviour, never content. Automatic fallback to the teacher on low confidence or failed
  citation verification.
- **Reasoning:** Fine-tuning for fact injection is the common failure mode — it produces a
  model that hallucinates confidently and can't be updated without retraining. Distilling
  *format* keeps the knowledge in the retrieval layer where it can be corrected.
- **Known limitation, stated up front:** the student will underperform the teacher on
  out-of-distribution questions. That is the expected result. Designing a cascade around a
  known limitation is a stronger signal than hiding it.

### D-005 — Public corpus: openly-licensed sources only; Arm ARM private-only

- **Status:** Active · **Date:** pre-project · **Milestone:** Pre-M0 (A5)
- **Decision:** Public corpus is CC-BY / Apache 2.0 / BSD / open-access only. Any document
  with unclear licensing is excluded, enforced by a unit test that fails the build if a
  `manifest.yaml` entry lacks a resolvable licence field. Arm's Architecture Reference Manual
  is confined to a private instance (M11) with a Terraform guardrail that refuses to apply if
  the instance would get public ingress.
- **Reasoning:** A policy note is not a control. The build-failing test and the apply-refusing
  guardrail are, and that distinction is the point.

### D-006 — Terraform state: S3 backend with native lockfile

- **Status:** Active · **Date:** 2026-07-28 · **Milestone:** M0
- **Trigger:** Local Terraform is v1.13.
- **Options:** (a) S3 + DynamoDB lock table (the conventional pattern); (b) S3 with
  `use_lockfile = true`.
- **Decision:** (b).
- **Reasoning:** Terraform ≥1.10 stores the lock in S3 itself. DynamoDB is one fewer resource,
  one fewer IAM policy statement, and ~$0.25/mo saved. Nearly every tutorial written before
  late 2024 still prescribes the DynamoDB table.
- **Cost delta:** −$0.25/mo vs the conventional pattern.

### D-007 — No NAT Gateway; workloads in public subnets with SG-restricted ingress

- **Status:** Active · **Date:** 2026-07-28 · **Milestone:** M0
- **Options:** (a) private subnets + NAT Gateway (the reflexive default); (b) public subnets,
  `assign_public_ip = true`, security group accepting ingress **only** from the front door's
  security group.
- **Decision:** (b).
- **Reasoning:** NAT Gateway is ~$33/mo — more than the entire rest of the stack combined.
  The security property that matters is *no inbound path from the internet*, and a security
  group delivers that as effectively as a private subnet does. M10 rearchitects the network
  anyway, so paying for NAT during M0–M9 buys nothing.
- **Rejected:** (a) — correct for a production system with compliance requirements, wrong for
  a dev environment that is destroyed nightly.
- **Cost delta:** −$33/mo.
- **Revisit at:** M10 (public exposure) and M12 (prod environment).

### D-008 — Fargate Spot for non-production workloads

- **Status:** Active · **Date:** 2026-07-28 · **Milestone:** M0
- **Decision:** Batch stages and any non-prod service run on Fargate Spot.
- **Reasoning:** ~70% discount. A Spot reclaim mid-demo is survivable and ECS reschedules;
  a reclaim mid-batch-job costs one re-run of a job that costs cents.
- **Revisit at:** M12 (prod uses on-demand).

### D-009 — CI/CD auth: GitHub OIDC, no long-lived AWS access keys

- **Status:** Active · **Date:** 2026-07-28 · **Milestone:** M0
- **Decision:** An IAM OIDC provider plus two role ARNs (`…-plan`, `…-deploy`), trust-scoped
  to `repo:praveennish/SpecSage:*`. No AWS credentials in GitHub secrets, ever.
- **Reasoning:** Static keys in CI are the most common credential-leak vector in public repos,
  and they cannot be scoped to a branch or environment. OIDC gives short-lived credentials
  bound to a specific repository and workflow.

### D-010 — HTTPS via CloudFront's default `*.cloudfront.net` certificate

- **Status:** Active · **Date:** 2026-07-30 · **Milestone:** M0
- **Supersedes:** D-010a, D-010b
- **Trigger:** Owner asked to avoid registering a domain (see D-011).
- **Options:** (a) HTTP-only until M10; (b) `nip.io` / `sslip.io`; (c) AWS App Runner's free
  TLS domain; (d) CloudFront's default domain and AWS-managed certificate.
- **Decision:** (d). Public entry is `https://<dist-id>.cloudfront.net`.
- **Reasoning:** CloudFront is the one AWS surface that terminates TLS on an AWS-owned
  hostname, so it is the only way to get a valid certificate without controlling a domain.
  CloudFront has no hourly charge and its perpetual free tier (1 TB egress, 10M req/mo)
  swallows demo traffic. Critically, `CloudFront → …` is also M10's required architecture, so
  standing it up now is week-4 work done early rather than throwaway scaffolding.
- **Rejected:** (a) — M8's remote MCP clients and M10's browser frontend both require TLS, so
  the cost reappears as rework. (b) — no way to prove domain control to ACM, therefore no
  certificate; dead end. (c) — abandons the ECS/Lambda compute model for a third runtime.
- **Trade-off accepted:** the URL is unmemorable and unbrandable. For a link that gets pasted
  rather than recited, this costs nothing real.
- **Reversibility:** adding a domain later is one ACM certificate, one `aliases` entry, one
  DNS record. No architectural change.
- **Cost delta:** −$1.60/mo vs D-010b.

#### D-010a — ALB with HTTPS *(superseded, 2026-07-28)*

Section B of the brief specified an HTTPS ALB with a checkpoint of
`curl https://<alb-dns>/health`. **This is not achievable**: ACM will not issue a certificate
for an `*.elb.amazonaws.com` hostname, so an ALB's own DNS name can serve HTTP or a
cert-mismatched HTTPS, never valid TLS. Surfaced as a blocking question rather than silently
downgraded to HTTP. *Superseded by D-010b.*

#### D-010b — ACM certificate on a registered domain *(superseded, 2026-07-30)*

Register a domain, issue a wildcard ACM certificate, terminate TLS at the ALB.
Correct and conventional; superseded because the owner declined to register a domain and
CloudFront's default certificate meets the same requirement for $0. *Superseded by D-010.*

### D-011 — No custom domain registered

- **Status:** Active · **Date:** 2026-07-30 · **Milestone:** M0
- **Supersedes:** D-011a
- **Trigger:** Owner asked directly whether the domain could be avoided.
- **Decision:** Register nothing. Rely on D-010.
- **Reasoning:** The domain existed solely to satisfy the TLS requirement. Once CloudFront
  supplies valid TLS for free, the domain's only remaining value is aesthetic. Removing it
  also removes a Route 53 hosted zone ($0.50/mo) and an annual renewal.
- **Cost delta:** −$1.60/mo.

#### D-011a — Register `praveennishchal.com` *(superseded, 2026-07-30)*

Selected over `specsage.dev` / `specsage.io` on the reasoning that a **personal** domain is
reusable across every future project while a project-specific domain is a dead end the moment
a second project exists. Availability was verified via `route53domains
check-domain-availability`. Superseded by D-011 — but **the personal-over-project-specific
reasoning still stands** if a domain is ever added.

### D-012 — Multi-project domain reuse: subdomains, never subpaths

- **Status:** Deferred (applies only if a domain is later added) · **Date:** 2026-07-28
- **Trigger:** Owner asked whether one domain could host multiple projects on subpaths.
- **Options:** (a) `specsage.<domain>` subdomains; (b) `<domain>/specsage/*` subpaths.
- **Decision:** (a).
- **Reasoning:** Subpaths require a **single shared front door** — one CloudFront distribution
  doing path-based origin routing, or one ALB with listener rules. Every project then shares a
  distribution, a WAF, and whichever Terraform state owns that front door. A bad deploy on
  project 2 can take project 1 down, and no project's edge can be destroyed independently —
  which directly contradicts D-017's stop-start model. Subpaths also force every application
  to become path-prefix-aware: FastAPI `root_path`, frontend asset URLs, cookie paths,
  redirect targets. That is a recurring bug source for zero benefit; the cost is identical
  either way.
- **Rejected:** (b) — coupling and blast radius, with no cost saving.

### D-013 — Infra split into three lifecycle layers

- **Status:** Active · **Date:** 2026-07-30 · **Milestone:** M0
- **Supersedes:** D-013a, D-013b
- **Trigger:** Owner proposed destroying the whole stack between sessions. Evaluating that
  proposal surfaced that "the whole stack" would include artifacts that are expensive or
  impossible to rebuild.
- **Decision:** Three layers, not two:

  | Layer | Lifecycle | Contents | Cost |
  |---|---|---|---|
  | `bootstrap` | Never destroyed | TF state bucket, OIDC provider, CI roles | ~$0.05/mo |
  | `data` | Never destroyed | S3 (raw, processed, snapshots, eval site), ECR, CloudFront | ~$1/mo |
  | `compute` | Destroyed between sessions | VPC, Lambda, Fargate task definitions | $0 idle |

- **Reasoning:** The original two-layer split separated *cost* (always-on vs ephemeral) but not
  *state*. Milestone artifacts have wildly different rebuild costs:

  | Artifact | Milestone | Rebuild cost | Placement |
  |---|---|---|---|
  | Raw corpus PDFs | M1 | Slow; some sources rate-limit or move | `data` |
  | `chunks.jsonl` | M2 | Cheap compute | `data` |
  | Qdrant index | M3 | Bedrock embedding calls + tens of minutes | snapshot to `data` |
  | Neo4j graph | M4 | **One LLM call per chunk** — dollars and hours | export to `data` |
  | `golden_qa.jsonl` | M7 | **Cannot be rebuilt** — hand-curated | **git**, not S3 |
  | QLoRA adapter | M9 | A GPU run | `data` + HuggingFace |

  The M4 graph is the sharp edge: destroying it to save compute and re-running an LLM call per
  chunk is a bad trade every single time.
- **Consequence:** `make down` snapshots Qdrant and exports Neo4j to S3 *before* destroying;
  `make up` restores from the latest snapshot rather than re-embedding. That restore path is
  worth building deliberately — "the system reconstitutes its own state from object storage in
  minutes" is a stronger claim than "it's always on."
- **Watch item:** Neo4j AuraDB free tier auto-pauses after a few days idle and is deleted after
  ~30 days idle. Verify the exact policy at M4; a stop-start schedule will hit it.

#### D-013a — Single always-on stack *(superseded, 2026-07-28)*
The v1 default. Superseded once the owner stated the service would not be live continuously.

#### D-013b — Two layers: persistent / ephemeral *(superseded, 2026-07-30)*
Split by *cost* — always-billed vs billed-only-while-up. Correct as far as it went; superseded
because it did not distinguish *stateless* from *stateful*, and would have destroyed the M4
graph on every teardown.

### D-014 — AWS account: personal, end-to-end

- **Status:** Active · **Date:** 2026-07-30 · **Milestone:** M0
- **Supersedes:** D-014a, D-014b · **Makes moot:** D-027
- **Trigger:** `aws sts get-caller-identity` resolved to
  `assumed-role/AWSReservedSSO_AWS-Common-Users-PermSet/…@rearc.io` in account
  `275279264324` — a **shared corporate account**, confirmed by `aws s3 ls` showing several
  other engineers' Terraform state and POC buckets plus two unrelated ECS clusters.
- **Options:** (a) corporate account throughout; (b) corporate for M0–M9, personal at M10;
  (c) personal end-to-end.
- **Decision:** (c).
- **Reasoning:** Four independent arguments, any one of which would be sufficient:
  1. **Data confidentiality.** The corpus, generated training pairs, hand-curated golden set,
     and adapter weights would be readable by everyone with access to the shared account.
  2. **Security posture.** A GitHub OIDC role creates a trust path from a public repository
     into the employer's AWS account — a decision their cloud team would want to make, not
     inherit.
  3. **Ownership.** Domains, infrastructure, and the model artifact registered in an employer's
     account belong to the employer. A portfolio piece you can lose on short notice is not a
     portfolio piece.
  4. **Operational friction.** SSO credentials are temporary and would need manual refresh
     before every Terraform run for four weeks.
- **Permissions actually verified** (via `iam simulate-principal-policy` against the SSO role,
  before the decision was made — the corporate option was assessed on evidence, not dismissed):

  | Action | Result |
  |---|---|
  | `iam:CreateRole`, `iam:CreateOpenIDConnectProvider` | allowed |
  | `ecs:CreateCluster`, `elasticloadbalancing:CreateLoadBalancer` | allowed |
  | `cloudfront:CreateDistribution`, `ecr:CreateRepository`, `s3:CreateBucket` | allowed |
  | `secretsmanager:CreateSecret`, `bedrock:InvokeModel` | allowed |
  | `iam:CreateUser` | **explicitDeny** |

  So the corporate account was *technically viable* — the decision rests on the four reasons
  above, not on a permission wall. Note `simulate-principal-policy` does not evaluate SCPs, so
  residual org-level restrictions were never ruled out.
- **Cost of the decision:** ~$35 on a personal card, against zero mid-project migration work.
- **Follow-up:** Use the owner's **existing** personal account rather than creating a new one —
  a new account costs an hour of setup and a fresh Bedrock model-access request in exchange for
  benefits (signup credits, billing isolation) that a `Project=SpecSage` cost-allocation tag
  and an AWS Budget deliver for free. Create a new account only if the existing one is shared,
  holds production workloads, or is tied to a business entity.

#### D-014a — Use the corporate account *(superseded, 2026-07-30)*
Initially the path of least resistance. Superseded on the four grounds above.

#### D-014b — Corporate for M0–M9, personal at M10 *(superseded, 2026-07-30)*
Reasoning: M10 is where the risk profile spikes (public endpoint, anonymous Bedrock spend), so
defer the switch to the milestone that actually needs it. Superseded because it left the
corpus and model artifact in shared storage for nine milestones, and because once cost was off
the table the migration step had no remaining justification.

### D-015 — `allowed_account_ids` provider guardrail

- **Status:** Active · **Date:** 2026-07-30 · **Milestone:** M0
- **Trigger:** Two AWS profiles on one laptop (corporate on `default`, personal on `specsage`)
  is a live footgun.
- **Decision:**
  ```hcl
  provider "aws" {
    region              = "us-east-1"
    profile             = "specsage"
    allowed_account_ids = [var.aws_account_id]
  }
  ```
  Makefile targets additionally assert the account ID before shelling out to Terraform.
- **Reasoning:** The provider fails at **plan** time if credentials resolve to any other
  account. Applying SpecSage into the corporate account becomes impossible rather than merely
  discouraged. Same principle as D-005: a control, not a note.

### D-016 — Credential isolation via a named `[specsage]` profile

- **Status:** Active · **Date:** 2026-07-30 · **Milestone:** M0
- **Decision:** Personal credentials live under `[specsage]` in `~/.aws/credentials`. The
  corporate SSO credentials keep `[default]`. Everything in this repo pins
  `AWS_PROFILE=specsage`.
- **Reasoning:** Defence in depth with D-015. The profile makes the wrong account unlikely; the
  guardrail makes it impossible.
- **Operational note:** the existing `[default]` profile was unparseable — shell `export`
  prefixes and quoted values pasted into an INI file. Failed in two ways at once: `Unable to
  locate credentials` (silent, looked like an empty file) then `InvalidClientTokenId` (loud but
  misleading — looked like an expired key, was actually a literal `"` as the first character of
  the key). Backup at `~/.aws/credentials.bak.*`.

### D-017 — Stop-start operating model with snapshot/restore

- **Status:** Active · **Date:** 2026-07-30 · **Milestone:** M0
- **Trigger:** Owner stated the system would be stood up and torn down per work session rather
  than run continuously.
- **Decision:** `make up` / `make down` drive the `compute` layer only. `make down` snapshots
  stateful services to the `data` layer first. Credentials are refreshed manually per session.
- **Reasoning:** Idle cost approaches zero, and the constraint forces a genuinely better
  property: **a system destroyed nightly cannot accumulate undocumented state.** Every piece
  has to be reconstructible from S3 and git or it does not survive to the next session. Most
  teams discover which of their state was load-bearing during an outage; this discovers it on
  day two, when it is free to fix.
- **Risk accepted:** a half-completed `destroy` can orphan billable resources. Mitigated by a
  `make verify-empty` target that lists any remaining billable resource after teardown.

### D-018 — Deploys are `workflow_dispatch`; PR checks stay automatic

- **Status:** Active · **Date:** 2026-07-30 · **Milestone:** M0
- **Trigger:** Consequence of D-017 — a deploy-on-merge workflow is a no-op most of the time
  when the target infrastructure is usually destroyed.
- **Decision:** PR → lint, unit tests, `terraform plan` as a PR comment, `docker build`. All
  automatic, all infrastructure-independent. Deploy → manual `workflow_dispatch` with an
  environment approval gate.
- **Reasoning:** The valuable half of CI (fast feedback on every change) needs no cloud
  resources at all and therefore stays fully automatic. The deploy half is gated on
  infrastructure that intentionally isn't there most of the time.

### D-019 — Request/response API on Lambda, not an always-on ECS service

- **Status:** Active · **Date:** 2026-07-30 · **Milestone:** M0
- **Supersedes:** D-019a · **Revises:** D-001's implied compute model (brief §A5)
- **Trigger:** Owner asked for alternatives after the v3 estimate. The ALB was ~$16 of a ~$20
  monthly bill and ~45% of the projected project total.
- **Decision:** The FastAPI service runs as a **Lambda container image** behind a Function URL,
  fronted by CloudFront. The ALB and the always-on ECS service are deleted.
- **Reasoning:**
  - An ALB bills hourly whether or not a request arrives. Scaling ECS to zero saves ~$2.70/mo
    and leaves the ~$16 ALB untouched — the ALB *is* the cost.
  - The workload is request/response with no long-lived connections and no state between
    invocations. That is precisely Lambda's shape.
  - Lambda's free tier (1M requests + 400k GB-s per month, perpetual) covers demo traffic.
  - Cold start on a container image is ~2–5s, acceptable for a demo endpoint and mitigable.
- **Why this doesn't weaken the portfolio story:** the owner's stated learning goals are vector
  databases, knowledge graphs, agent evaluation, MCP, and small-model fine-tuning. None of them
  need Fargate. ECS/Fargate is explicitly in the "done a hundred times" category. Serverless-
  first with a documented cost rationale is a stronger staff-level answer than uniform Fargate.
- **Honest cost:** two compute models instead of one. Justified by genuinely different workload
  shapes (see D-020), but it is added surface area and should be stated as such.
- **Cost delta:** −$16.40/mo.
- **Revisit at:** M12, if prod requires characteristics Lambda cannot provide.

#### D-019a — ALB + always-on ECS Fargate service *(superseded, 2026-07-30)*
The brief's §A5 default. Superseded on cost, with the batch half of the Fargate story
preserved intact under D-020.

### D-020 — Batch pipeline stages stay on Fargate + Step Functions

- **Status:** Active · **Date:** 2026-07-30 · **Milestone:** M1–M3
- **Decision:** Ingestion (M1), parsing (M2), embedding (M3), graph extraction (M4), and the
  eval run (M7) remain **one-off ECS Fargate tasks chained by Step Functions**.
- **Reasoning:** Fargate one-off tasks bill per second — a 10-minute ingestion run costs about
  a cent. There is nothing to save by moving them, and they are the wrong shape for Lambda
  (long-running, memory-hungry PDF parsing, well past the 15-minute ceiling in some cases).
  This also preserves the Step Functions orchestration story from the original design.
- **Relationship to D-019:** the split is by workload shape, not by preference — sub-second
  request/response on Lambda, multi-minute batch on Fargate. That is the defensible framing.

### D-021 — Vector store: Qdrant Cloud free tier

- **Status:** Active · **Date:** 2026-07-30 · **Milestone:** M3
- **Options:** (a) self-hosted Qdrant on Fargate with EFS persistence; (b) Qdrant Cloud free
  tier (1 GB, free indefinitely); (c) LanceDB/FAISS over S3 with no server at all.
- **Decision:** (b).
- **Reasoning:** 1 GB comfortably holds this corpus. Removes an always-on Fargate service, an
  EFS filesystem, a mount target, and the operational burden of running a stateful database —
  for $0. The M3 learning goal is *using* a vector database well (dimensionality, distance
  metric, recall behaviour, hybrid expansion), not operating one.
- **Rejected:** (a) — ~$10/mo plus EFS plus complexity, buying operational experience that
  isn't a stated learning goal. (c) — genuinely serverless and interesting, but diverges from
  the brief's Qdrant choice and gives up the payload-filtering API that M5's hybrid expansion
  relies on.
- **Cost delta:** −$10/mo and one fewer stateful service to snapshot.

### D-022 — Fine-tuning compute: Modal / Kaggle free tiers

- **Status:** Active · **Date:** 2026-07-30 · **Milestone:** M9
- **Options:** (a) AWS `g5.xlarge` spot; (b) Modal (monthly free credits); (c) Kaggle (free
  T4 hours per week).
- **Decision:** (b) or (c) for training; Modal for serving the student.
- **Reasoning:** Saves ~$10 — but the real win is **deleting the EC2 G-instance spot quota
  request**, which is the only item on the setup checklist with a multi-day lead time and no
  way to accelerate it. New AWS accounts default to zero G-instance spot vCPUs, and the failure
  mode is a `MaxSpotInstanceCountExceeded` error that reads like over-usage when you are
  actually allowed none. Filing that request in week 3 would block on AWS support during the
  single most important week of the project.
- **Consequence:** the cheapest option here is also the one that cannot eat week 3. Serving is
  on a third-party GPU provider regardless (per the brief), so training there too adds no new
  vendor.
- **Cost delta:** −$10 and −1 critical-path dependency.

### D-023 — Per-stage model right-sizing

- **Status:** Active · **Date:** 2026-07-30 · **Milestone:** M4, M6, M7, M9
- **Trigger:** LLM tokens were the largest single line in the v3 project estimate ($20–80).
- **Decision:**

  | Stage | Model | Rationale |
  |---|---|---|
  | M4 graph extraction (~3k calls) | Haiku 4.5 | Structured extraction under a quoted-source constraint. ~$9 vs ~$45 on Opus. |
  | M7 LLM-as-judge (150 Q × weekly) | Haiku 4.5 | ~$0.70/run. M7 already measures judge/human disagreement, so weakness is detectable. |
  | M6 synthesis / M9 teacher | Sonnet 5 | The one place quality **is** the product — M9 distils the teacher's citation formatting, so a weak teacher yields a weak student. |
  | M3 embeddings | `amazon.titan-embed-text-v2:0` | Pennies at this corpus size. |

- **Reasoning:** Same right-sizing judgement as D-003, applied to inference instead of
  training. The stages differ by an order of magnitude in how much model capability they
  actually need; using one model everywhere overpays by 3–5×.
- **Timing note:** Sonnet 5 carries introductory pricing through 2026-08-31, which covers the
  entire project window.
- **Cost delta:** project LLM spend $80 → ~$30.

### D-024 — Prompt caching on repeated instruction prefixes

- **Status:** Active · **Date:** 2026-07-30 · **Milestone:** M4, M9
- **Decision:** Manual `cache_control` breakpoints on the shared instruction prefix in M4's
  extraction prompt and M9's generation prompt.
- **Reasoning:** Cache reads cost ~0.1× input price. M4 sends a near-identical extraction
  instruction thousands of times with only the chunk varying — a textbook shared-prefix
  pattern. **Automatic** prompt caching is not available on Bedrock; manual `cache_control` is.
- **Design constraint this imposes:** the prompt-building path must keep the instruction prefix
  byte-identical across calls. No timestamps, no per-request IDs, no non-deterministic JSON
  serialisation anywhere in the prefix.

### D-025 — Batch API discount: deferred

- **Status:** **Open** · **Date:** 2026-07-30 · **Milestone:** M9
- **Question:** The Message Batches API is 50% off and M9's ~1,000 offline generations plus
  M7's eval runs are ideal batch workloads. But **Batches is not available on Bedrock.**
- **Options:** (a) skip the discount, keep everything on Bedrock; (b) run offline generation
  against the first-party Anthropic API while the live serving path stays on Bedrock.
- **Trade-off:** (b) saves roughly $6–10 and costs one more credential to manage plus a split
  in the "everything runs on AWS" narrative.
- **Decision:** deferred to M9. Not on the critical path for M0.

### D-026 — Distilled model published to HuggingFace; weights gated pending ToS review

- **Status:** **Open** · **Date:** 2026-07-30 · **Milestone:** M9
- **Decision (settled part):** The adapter is published to **HuggingFace Hub**, not to any AWS
  service. This means no AWS account migration was ever required to make the model public —
  which removed one of D-014b's stated justifications.
- **Open part:** Distilling Claude's outputs into Qwen and publishing the weights touches
  Anthropic's terms on using model outputs to train other models. **The owner must read the
  Bedrock service terms before publishing weights.**
- **Low-risk fallback if the terms don't permit it:** publish the training *code*, the
  methodology, and the three-way comparison table; keep the weights private or gated. The
  comparison table is the interview deliverable — nobody downloads the adapter.

### D-027 — Account migration at M10 *(superseded)*

- **Status:** **Superseded** by D-014 · **Date:** 2026-07-30
- **Was:** migrate from the corporate to a personal account at M10, the milestone where public
  exposure and anonymous Bedrock spend begin.
- **Why moot:** D-014 puts the project in the personal account from M0. There is nothing to
  migrate. Retained because the *reasoning* — that M10 is where the risk profile changes
  discontinuously — still informs M10's threat model.

### D-028 — Bedrock access via `AnthropicBedrockMantle`; model IDs verified

- **Status:** Active · **Date:** 2026-07-30, **revised 2026-07-31** · **Milestone:** M3, M6
- **Decision:** Use the `AnthropicBedrockMantle` client (the Messages-API Bedrock endpoint),
  not `AnthropicBedrock` (the legacy `bedrock-runtime` `InvokeModel` path).

- **Model IDs — verified by actual invocation on account `941500193593`, not by listing:**

  | Purpose | ID to use | Verified |
  |---|---|---|
  | Graph extraction, LLM-as-judge | `us.anthropic.claude-haiku-4-5-20251001-v1:0` | ✅ invoked |
  | Embeddings | `amazon.titan-embed-text-v2:0` | ✅ invoked, 1024 dims |
  | Teacher synthesis | `us.anthropic.claude-sonnet-5` | ❌ access not yet granted |

- **Finding 1 — Claude models require a cross-region inference profile, not the bare model
  ID.** The bare `anthropic.claude-haiku-4-5-…` is rejected for on-demand throughput; the
  `us.`-prefixed inference profile ID works. `amazon.titan-embed-text-v2:0` takes the bare ID.
  So the prefix rule is per-model-family, not global — which is exactly why these are pinned
  in config after an invocation test rather than constructed by rule.

- **Finding 2 — `ListFoundationModels` is not an access check.** It returned all four IDs on an
  account that could invoke only two of them. It reports what exists in the region, not what
  you are entitled to call. The only reliable check is an actual invocation, which is what
  `scripts/check-bedrock.sh` does.

- **Reasoning:** Bedrock IDs carry an `anthropic.` provider prefix that first-party IDs do not;
  the 5-family IDs are bare where Haiku 4.5 carries a dated suffix; and Claude models need an
  additional `us.` inference-profile prefix that Titan does not. Three independent
  inconsistencies in four IDs. Pin them; do not derive them. Bedrock is partner-priced
  separately from first-party rates — D-023's figures are first-party and used for **ratios**,
  not absolute Bedrock costs.

- **Resolved 2026-08-02 — full account model survey.** Every Anthropic model listed in
  `us-east-1` was invoked, not just the three originally planned. Result: this account has
  access to the **4.6-and-earlier generation**, not the newest release wave.

  | Model | Status |
  |---|---|
  | Haiku 4.5, Sonnet 4.6, Sonnet 4.5, Opus 4.6, Opus 4.5, Opus 4.1 | ✅ invokable |
  | Sonnet 5, Opus 5, Opus 4.8, Opus 4.7, Fable 5 | ⛔ `AccessDeniedException: … not available for this account` |

  This reframes the original "Sonnet 5 is denied" finding: it was never a Sonnet-5-specific
  problem, it is an account-wide gap on models newer than the 4.6 generation. The same
  `AccessDeniedException: <model> is not available for this account` — distinct from an IAM
  `not authorized to perform bedrock:InvokeModel` error — fires for all five.

- **Decision — use Sonnet 4.6 as the teacher, not a placeholder.** M6/M9's teacher model
  changes from `claude-sonnet-5` to `us.anthropic.claude-sonnet-4-6`. This is not "unblock and
  revisit" — Sonnet 4.6 is a fully capable teacher, and the project proceeds on it. Sonnet 5
  access, if it clears, is an opportunistic upgrade evaluated on the M9 three-way comparison
  table, not a dependency anything is waiting on.
- **Cost note:** Sonnet 4.6 is **not** covered by Sonnet 5's introductory pricing window
  (through 2026-08-31, see D-023). Re-check current Sonnet 4.6 rates before finalizing M9's
  budget line — the ratio-based estimates in D-023 assumed the intro rate.
- **Still open:** whether to pursue Sonnet 5 access at all (support case vs. AWS Sales contact)
  is deferred — it is no longer blocking anything.

---

## 4. Open questions

| ID | Question | Blocking | Resolve by |
|---|---|---|---|
| D-025 | Take the 50% Batch API discount at the cost of splitting Bedrock / first-party? | No | M9 |
| D-026 | Do Bedrock/Anthropic terms permit publishing weights distilled from Claude outputs? | No | Before M9 publish |
| — | Neo4j AuraDB free-tier idle-deletion policy under a stop-start schedule | No | M4 |
| — | Lambda cold-start acceptability for streamed `/answer` responses at M10 | No | M10 |
| — | Whether M12's prod environment justifies reverting D-019 for the API tier | No | M12 |

---

## 5. Changelog

| Date | Change |
|---|---|
| 2026-07-28 | D-006 … D-009, D-010a, D-012, D-013a created (plan v1) |
| 2026-07-28 | D-010b, D-011a, D-013b created; D-010a superseded (plan v2) |
| 2026-07-30 | D-010, D-011 created; D-010b, D-011a superseded (plan v3) |
| 2026-07-30 | D-014, D-015, D-016 created; D-014a, D-014b superseded |
| 2026-07-30 | D-013, D-017, D-018 created; D-013b superseded |
| 2026-07-30 | D-019 … D-028 created; D-019a superseded; D-027 made moot (plan v4) |
