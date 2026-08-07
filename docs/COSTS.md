# SpecSage — Costs

Estimated vs actual. Updated whenever infrastructure changes. Reasoning behind each
cost-shaping choice is in [DECISION-LOG.md](./DECISION-LOG.md).

**Status:** nothing provisioned yet. All figures are estimates.

---

## 1. Estimate history

The estimate moved four times. Each move was driven by a specific decision, not by refinement.

| Plan | Idle $/mo | 24/7 $/mo | Project total | What changed |
|---|---|---|---|---|
| v1 | 22.35 | 22.35 | ~$120 | Baseline: ALB + always-on Fargate, no NAT (D-007) |
| v2 | 2.65 | 21.75 | ~$110 | Persistent/ephemeral split (D-013b); domain added (D-011a) |
| v3 | 1.06 | 20.00 | ~$100 | Domain dropped, CloudFront default TLS (D-010, D-011) |
| **v4** | **~1.00** | **~1.00** | **~$35** | ALB deleted (D-019), Qdrant Cloud (D-021), free-tier GPU (D-022), model right-sizing (D-023) |

---

## 2. Current estimate (v4)

### Persistent — always billed

| Resource | Est. $/mo | Note |
|---|---|---|
| CloudFront distribution | 0.00 | Free tier: 1 TB egress + 10M req/mo, perpetual |
| Lambda | 0.00 | Free tier: 1M req + 400k GB-s/mo, perpetual |
| S3 (state, corpus, snapshots, eval site) | 0.30 | Grows with corpus; a few GB |
| ECR | 0.10 | Lifecycle policy keeps 10 images |
| CloudWatch Logs | 0.50 | 7-day retention |
| Secrets Manager | 0.40 | 1 secret |
| Qdrant Cloud | 0.00 | Free tier, 1 GB |
| Neo4j AuraDB | 0.00 | Free tier |
| **Total** | **~$1.30** | |

### Per-use — billed only while running

| Resource | Rate | Typical |
|---|---|---|
| Fargate Spot batch task | ~$0.0037/hr per 0.25 vCPU / 0.5 GB | ~$0.01 per 10-min pipeline run |
| Bedrock — Titan embeddings | per-token, negligible | pennies for full corpus |
| Bedrock — Haiku 4.5 | $1 / $5 per MTok* | M4 full extraction ≈ $9 |
| Bedrock — Sonnet 5 | $2 / $10 per MTok* (intro, through 2026-08-31) | M9 dataset build ≈ $12 |
| Modal / Kaggle GPU | free tier | M9 training run: $0 |

\* First-party Anthropic rates, used for **ratios**. Bedrock is partner-priced separately —
replace with measured figures once M3 runs.

### Project total (4 weeks)

| Bucket | Estimate |
|---|---|
| Infrastructure (idle + per-use) | $5 |
| Bedrock — M4 graph extraction | $9 |
| Bedrock — M9 dataset build | $12 |
| Bedrock — M6/M7 dev, demo, eval runs | $8 |
| GPU training + serving | $0 |
| **Total** | **~$35** |

Floor if D-025 (Batch API, 50% off) is taken and Kaggle handles training: **~$20**.

---

## 3. Where the money went, and where it didn't

| Avoided | Saved/mo | Decision |
|---|---|---|
| NAT Gateway | $33.00 | [D-007](./DECISION-LOG.md#d-007--no-nat-gateway-workloads-in-public-subnets-with-sg-restricted-ingress) |
| Application Load Balancer | $16.40 | [D-019](./DECISION-LOG.md#d-019--requestresponse-api-on-lambda-not-an-always-on-ecs-service) |
| Self-hosted Qdrant + EFS | $10.00 | [D-021](./DECISION-LOG.md#d-021--vector-store-qdrant-cloud-free-tier) |
| Always-on Fargate service | $2.70 | [D-019](./DECISION-LOG.md#d-019--requestresponse-api-on-lambda-not-an-always-on-ecs-service) |
| Route 53 zone + domain | $1.60 | [D-010](./DECISION-LOG.md#d-010--https-via-cloudfronts-default-cloudfrontnet-certificate), [D-011](./DECISION-LOG.md#d-011--no-custom-domain-registered) |
| DynamoDB state lock table | $0.25 | [D-006](./DECISION-LOG.md#d-006--terraform-state-s3-backend-with-native-lockfile) |
| **Total avoided** | **$63.95/mo** | |

One-time savings: ~$10 of GPU spend ([D-022](./DECISION-LOG.md#d-022--fine-tuning-compute-modal--kaggle-free-tiers)),
and roughly 3–5× on LLM tokens via per-stage model right-sizing
([D-023](./DECISION-LOG.md#d-023--per-stage-model-right-sizing)).

The v4 idle figure already clears M12's stated target of "under $20–30/month idle" by more than
an order of magnitude. M12's cost work becomes verification rather than optimisation.

---

## 4. Cost controls in place

| Control | Where | Status |
|---|---|---|
| `Project=SpecSage` cost-allocation tag on every resource | Terraform default tags | M0 |
| AWS Budget with alert at a threshold you set | `infra/bootstrap` | M0 |
| 7-day CloudWatch log retention | Terraform | M0 |
| ECR lifecycle policy — keep 10 images | Terraform | M0 |
| `make down` teardown between sessions | Makefile | M0 |
| `make verify-empty` — lists any remaining billable resource | Makefile | M0 |
| Daily LLM-spend metric → SNS → feature-flag kill switch | M10 | Not built |

---

## 5. Actuals

| Month | Estimated | Actual | Delta | Notes |
|---|---|---|---|---|
| 2026-08 | ~$1.30 | TBD | — | `bootstrap` + `data` applied 2026-08-07. Account has pre-existing non-SpecSage spend (two prior budgets), so filter on `Project=SpecSage` once the tag activates. |

### Deployed so far

| Resource | Billing model | Est. $/mo |
|---|---|---|
| S3 state bucket | per GB — a few KB | ~$0.01 |
| S3 artifacts bucket | per GB — empty until M1 | $0.00 |
| S3 web bucket | one 2 KB object | ~$0.01 |
| ECR repository | per GB — empty until first push | $0.00 |
| CloudFront distribution | per request/GB, **no hourly charge** | $0.00 (free tier) |
| OIDC provider, 2 IAM roles, budget | free | $0.00 |
| **Total live** | | **~$0.02/mo** |

The interesting number is CloudFront: a public HTTPS endpoint with a valid certificate,
costing nothing while idle. That is the whole reason no domain and no load balancer exist
([D-010](./DECISION-LOG.md#d-010--https-via-cloudfronts-default-cloudfrontnet-certificate),
[D-019](./DECISION-LOG.md#d-019--requestresponse-api-on-lambda-not-an-always-on-ecs-service)).

Record actuals from Billing → Cost Explorer filtered on `Project=SpecSage`. Note any line item
that exceeds its estimate by more than 2×, and why.
