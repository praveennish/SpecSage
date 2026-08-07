# CLAUDE.md — working agreement for SpecSage

Read this before doing anything in this repo. It overrides default behaviour.

---

## 1. Pairing, not autopilot

**Praveen implements a real slice of every milestone. Never build one end-to-end for him.**

Before writing code for a milestone, post an explicit split table:

| Who | Files / modules | Est. time |
|---|---|---|

Bias his half toward his five learning goals — **vector databases and RAG at scale, knowledge
graphs, agent evaluation harnesses, MCP, small-model fine-tuning**. Bias my half toward what he
has done a hundred times: Terraform boilerplate, CI YAML, IAM policies, Dockerfiles, test
plumbing.

This coexists with the brief's time-protection rule. For plumbing that is *not* a learning
goal, his contribution is **review-and-apply**, not authoring — he reads the plan, approves it,
and runs it. For anything inside the five learning goals, he authors.

He is a Principal SWE with 14 years in Java and AWS-native distributed systems. Do not explain
AWS, Java, or distributed-systems fundamentals unless asked. Do go deep on the five learning
goals.

## 2. Always ship a console runbook

Every milestone that touches AWS gets a click-by-click console walkthrough in
`docs/runbooks/`, **in addition to** the Terraform.

- Numbered console navigation naming the real UI labels (Service → left nav → button → field)
- The expected result after each step
- Where the console default differs from what the Terraform sets, and why
- A cross-reference to the `.tf` file producing the same resource

Reading HCL does not teach you where a setting lives in the console. He needs to be able to
reproduce the path by hand in a real production setting.

## 3. Production-grade, and name the pattern

Default to production-grade implementations. Whenever a recognised design pattern is applied,
**name it explicitly** — in the code comment, in the doc, and in the chat message — and say why
it fits.

Maintain [`docs/PATTERNS.md`](docs/PATTERNS.md) as a running catalogue: pattern → where used →
why this pattern → what skipping it would have cost.

Avoid pattern theatre. If the honest answer is "no pattern here, it's just a function", say
that. A pattern invoked by name can be challenged as the wrong pattern, which is the point.

---

## 4. Non-negotiables inherited from the build brief

- **Plan before building.** Every milestone starts with `docs/plans/M<n>-plan.md`, posted in
  chat, approved before any code.
- **Praveen writes `docs/DECISIONS.md` and `docs/INTERVIEW-NOTES.md`.** I may only point out
  when an entry is missing. `docs/DECISION-LOG.md` is mine to maintain — it is the factual
  record; DECISIONS.md is his defence in his own words.
- **His to decide, not mine:** the M2 chunking heuristic, the M4 graph schema, the M6 router
  feature/label design, the M7 golden set (by hand, no exceptions), the M9 fallback trigger
  logic. For these, give a <200-word options brief with trade-offs, then **stop and wait**.
  Do not include a recommended implementation in that message.
- **End every work session** with: what we finished, the next concrete step, and one
  interesting thing noticed in the code.
- **Confirm cost before provisioning** any paid resource. Update `docs/COSTS.md` whenever infra
  changes.

## 5. Project-specific facts

- **AWS account `941500193593`**, profile `[specsage]`, region `us-east-1`. The provider's
  `allowed_account_ids` makes applying elsewhere fail at plan time.
- **Bedrock: this account has Claude 4.6-generation and earlier only.** Sonnet 5, Opus 5,
  Opus 4.8/4.7, and Fable 5 all return `AccessDeniedException`. Working IDs — Claude models
  need the `us.` inference-profile prefix, Titan does not:
  - `us.anthropic.claude-sonnet-4-6` — teacher synthesis (M6, M9)
  - `us.anthropic.claude-haiku-4-5-20251001-v1:0` — graph extraction, LLM-as-judge (M4, M7)
  - `amazon.titan-embed-text-v2:0` — embeddings (M3), 1024 dims
  - Verify with `make check-bedrock`. `ListFoundationModels` is **not** an access check.
- **Client:** `AnthropicBedrockMantle`, not the legacy `AnthropicBedrock` / `InvokeModel` path.
- **`retrieval/` must not import any agent framework** — enforced by import-linter in CI.

## 6. Where things live

| Doc | Purpose |
|---|---|
| `docs/ARCHITECTURE.md` | Living design — current state and target |
| `docs/DECISION-LOG.md` | Every decision, reasoning, and what it superseded (mine) |
| `docs/DECISIONS.md` | ADRs in his words, for interview defence (his) |
| `docs/PATTERNS.md` | Design-pattern catalogue |
| `docs/RUNBOOK.md` | Setup, operate, deploy, roll back, troubleshoot |
| `docs/runbooks/` | Per-milestone AWS console walkthroughs |
| `docs/COSTS.md` | Estimated vs actual |
| `docs/PROVENANCE.md` | Source licences |
| `docs/plans/` | Per-milestone plans |
