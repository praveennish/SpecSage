# M1 Plan — Data Acquisition as a Cloud Job

**Status:** awaiting approval · **Branch:** `m1-data-acquisition`
**Context reloaded from:** `docs/ARCHITECTURE.md`, `docs/DECISION-LOG.md`, `docs/PROVENANCE.md`

---

## 1. Goal

Corpus acquisition running as a real ECS Fargate task writing to S3, with airtight licence
tracking enforced by a build-failing test.

**Release checkpoint:** trigger the Fargate task from the AWS console; confirm raw documents
and a fully-populated `manifest.yaml` land in `s3://specsage-artifacts-941500193593/raw/`.

Non-goals: parsing, chunking, embedding. M1 downloads and catalogues. Nothing reads the
contents.

---

## 2. Shape

```
EventBridge rule (on-demand / scheduled)
        │
        ▼
ECS Fargate one-off task  ──▶  s3://specsage-artifacts-941500193593/
   python -m ingestion              raw/<source_id>/<filename>
                                    raw/manifest.yaml
                                          │
                                          └──▶ docs/PROVENANCE.md  (mirrored, committed)
```

**Fargate returns here, and this is [D-020](../DECISION-LOG.md) paying off.** Removing the
always-on ECS *service* at M0 did not remove Fargate — one-off tasks bill per second, so a
10-minute ingestion run costs about a cent. Request/response on Lambda, batch on Fargate,
split by workload shape.

The artifacts bucket already exists in the `data` layer. M1 adds only: ECS cluster, task
definition, task execution role, task role, EventBridge rule, and a CloudWatch log group.

---

## 3. Files

```
ingestion/
  __init__.py          (exists — docstring only)
  __main__.py          entrypoint: python -m ingestion
  sources.py           the source registry — declarative, one entry per document
  fetch.py             download with retry/backoff, streaming to disk, SHA256 as it goes
  manifest.py          manifest schema + read/write + PROVENANCE.md rendering
  licences.py          licence resolution and the allow-list          <- YOURS
  storage.py           S3 upload, idempotent by content hash

tests/ingestion/
  test_licences.py     the build gate                                 <- YOURS
  test_manifest.py     schema round-trip, required-field enforcement
  test_fetch.py        retry/backoff against a mocked transport
  fixtures/            2-3 sample docs per structural type

infra/compute/
  ecs.tf               cluster, task definition, EventBridge rule
  iam-task.tf          task execution role + task role (least privilege)
```

---

## 4. AWS resources and cost delta

| Resource | Notes | $/mo |
|---|---|---|
| ECS cluster | free — a cluster is a namespace, not compute | $0.00 |
| Fargate Spot task | 0.5 vCPU / 1 GB, ~10 min per run | ~$0.01/run |
| EventBridge rule | free tier covers this comfortably | $0.00 |
| CloudWatch log group | 7-day retention | ~$0.05 |
| S3 storage | corpus size dependent — see §6 | ~$0.05–0.30 |
| S3 PUT requests | one per document | negligible |
| **Total delta** | | **~$0.15/mo + $0.01/run** |

No NAT Gateway ([D-007](../DECISION-LOG.md)) — the task runs in a public subnet with
`assign_public_ip = true` and a security group with **no inbound rules at all**. It needs
egress to the internet (to fetch documents) and nothing needs to reach it.

---

## 5. Tests

| Test | Type | Asserts |
|---|---|---|
| `test_every_entry_has_resolvable_licence` | unit | **fails the build** if any `manifest.yaml` entry lacks a licence resolving to the allow-list |
| `test_unknown_licence_is_rejected` | unit | an entry with `licence: unknown` or an unlisted SPDX id fails |
| `test_index_only_sources_are_flagged` | unit | arXiv/blog entries carry `usage: index_only`, never `full_text` |
| `test_manifest_round_trip` | unit | write → read → identical |
| `test_sha256_matches_content` | unit | recorded hash matches the bytes on disk |
| `test_fetch_retries_on_429` | unit | backoff against a mocked transport, no real network |
| `test_fetch_gives_up_after_n` | unit | bounded retries, clear failure |

The first three are the licence gate. They run in CI on every PR, so a source added without a
resolvable licence cannot merge.

---

## 6. **Yours to decide — the source list**

The brief is explicit:

> **Mine to decide:** final source list — show me your proposed list and page counts before
> downloading, so I can trade breadth against corpus quality.

### What the trade actually costs downstream

| More sources means | Because |
|---|---|
| More M2 chunking work | each structural type needs its own boundary heuristic and test fixtures |
| More M3 embedding spend | Titan is cheap, but it's per-token and linear |
| **More M4 graph cost** | the second extraction pass is **one LLM call per chunk with no regex hit** — this is the expensive one |
| Wider M7 golden set | you hand-curate 50–100 pairs; they must cover what the corpus contains |

And the counter-pressure: **M2's tests require 2–3 sample pages per document *type*** (ISA spec,
datasheet, kernel doc, arXiv paper — they differ structurally). So breadth of *type* is
load-bearing even at low volume; breadth of *volume* within a type is not.

### Proposed tiers

Page counts are **estimates** and marked as such. The ingestion job reports actual counts and
**halts if the total exceeds a configured ceiling**, so a surprise cannot silently blow up M3/M4.

**Tier A — spec-shaped, densely cross-referenced. The graph lives here.**

| Source | Licence | Est. pages | Why |
|---|---|---|---|
| RISC-V Unprivileged ISA | CC-BY 4.0 | ~280 | Dense "see Section X.Y" — ideal M4 material |
| RISC-V Privileged ISA | CC-BY 4.0 | ~150 | Heavy cross-refs into Unprivileged |
| Devicetree Specification | BSD | ~120 | Clean numbered sections |
| Linux `Documentation/arch/arm64` | GPL-2.0 w/ docs exception | ~40 files | Different structure — RST, not PDF |
| **Tier A total** | | **~550 pages + 40 files** | |

**Tier B — register-level hardware docs. Apache 2.0, structurally different again.**

| Source | Licence | Est. pages | Why |
|---|---|---|---|
| OpenTitan docs (subset) | Apache 2.0 | ~150 | Register definitions, IP block docs |
| Zephyr RTOS docs (subset) | Apache 2.0 | ~200 | **Full Zephyr docs are thousands of pages — subset only** |
| **Tier B total** | | **~350 pages** | |

**Tier C — SoC datasheets. A genuinely different document shape.**

| Source | Licence | Est. pages | Why |
|---|---|---|---|
| BCM2711 peripherals | open publication | ~200 | Register tables, the datasheet archetype |
| ESP32 Technical Reference | open publication | **~1000** | ⚠️ Would be ~45% of the corpus on its own |
| **Tier C total** | | **~1200 pages** | |

**Tier D — indexed and cited only, never republished.**

| Source | Licence | Est. pages | Why |
|---|---|---|---|
| 15–20 arXiv papers | per-paper — checked individually | ~250 | Fourth structural type; M2 needs it |
| 5–10 industry blogs | all rights reserved | ~40 | Index + cite only |
| **Tier D total** | | **~290 pages** | |

### My recommendation, and the reasoning

**Tier A + Tier D + BCM2711 only from Tier C. Skip Tier B and skip ESP32.** ≈ **1,040 pages.**

- **All four structural types are represented** — ISA spec (A), kernel doc (A), datasheet
  (BCM2711), arXiv paper (D). M2's tests are satisfied.
- **Graph density is concentrated in Tier A**, which is where cross-references are thickest.
  Adding Tier B adds pages without adding much reference structure.
- **ESP32 alone would be ~45% of the corpus** for one more instance of a type BCM2711 already
  covers. It is the single worst pages-per-unit-of-insight item on the list.
- Tier B is the best candidate to add later if the corpus feels thin after M3 — it's Apache 2.0
  and easy to append.

**But it's your call.** If you'd rather have a bigger corpus to make M3 recall numbers more
interesting, Tier B is the cheapest addition. If you want the fastest path to M7, cut Tier D's
paper count to 8–10.

---

## 7. Also yours — the licence gate design

The second decision, and the reason this is a design task rather than plumbing:

- **What counts as "resolvable"?** An SPDX identifier from an allow-list? A URL to a licence
  file? Both?
- **What happens to an arXiv paper with no explicit licence?** Excluded entirely, or included
  as `index_only` with a recorded justification?
- **Do blog posts get their own status?** They're all-rights-reserved by default; indexing and
  citing is arguably fair use, republishing is not. Does the schema encode that distinction, or
  does policy live in code?

Those answers shape what the public corpus can legally contain, and the test that enforces them
is the artifact you point at when an interviewer asks how you handled licensing.

---

## 8. Split

| Who | What | Est. |
|---|---|---|
| **You** | Final source list (§6) | 20 min |
| **You** | `licences.py` + `test_licences.py` — the gate | 45 min |
| Me | `fetch.py`, `storage.py`, `manifest.py`, retry/backoff, SHA256 |  |
| Me | `infra/compute/ecs.tf` + task IAM |  |
| Me | `docs/runbooks/M1-ingestion-console.md` |  |
| Me | Everything else in §3 |  |

**Honest note:** M1 is mostly data plumbing. Fargate task definitions, EventBridge rules, and
S3 writes are well inside your existing experience. The licence gate is the one genuine design
decision. If you'd rather bank the time for M2 (chunking — the highest-leverage decision in the
pipeline) and M7, take §6 and §7 only and let me do the rest.

---

## 9. Open questions

1. **Source list** — §6. Blocking.
2. **Licence gate semantics** — §7. Blocking for `licences.py`, not for the rest.
3. **Corpus size ceiling** — what total page count should halt the job? I'd suggest 1,500 as a
   tripwire against a source being larger than estimated.
4. **Schedule** — EventBridge rule on-demand only, or also weekly? On-demand is enough for M1;
   scheduled re-fetch matters more at M12.

---

## 10. Docs to update at end of M1

`PROVENANCE.md` (real entries, mirrored from manifest), `ARCHITECTURE.md` (pipeline stage 1
exists), `COSTS.md` (M1 delta + first real S3 numbers), `RUNBOOK.md` (how to trigger and
re-run ingestion), `DECISION-LOG.md` (source list rationale, licence gate design),
`runbooks/M1-ingestion-console.md` (new).
