# SpecSage — Data Provenance

Every data source in the corpus: URL, licence, retrieval date, and content hash. This file is
mirrored from `ingestion/manifest.yaml` and is the authoritative human-readable record.

**Status:** empty until M1.

---

## Rules

1. **Openly-licensed sources only** in the public corpus. Any document whose licence cannot be
   resolved to a specific, named licence is **flagged and excluded** — not included with a
   guess.
2. **A unit test fails the build** if any `manifest.yaml` entry lacks a resolvable `license`
   field. Licence tracking is a build gate, not a convention.
3. **Indexed and cited, never republished.** arXiv papers and industry blog posts are embedded
   and cited with links to the original. Their text is not served verbatim.
4. **The Arm Architecture Reference Manual is never in this file.** It is downloaded by the
   owner under Arm's free developer licence, is licensed for personal/development use only, is
   never committed to git, and is never written to any S3 bucket used by a public deployment.
   Its isolation is enforced by a Terraform guardrail that refuses to apply if the M11 private
   instance would receive public ingress. See §3.

---

## 1. Public corpus

> Populated at M1.

| Source | URL | Licence | Retrieved | SHA256 | Pages | Use |
|---|---|---|---|---|---|---|
| — | — | — | — | — | — | — |

Planned sources (final list is the owner's call at M1):

| Source | Expected licence | Use |
|---|---|---|
| RISC-V Unprivileged + Privileged ISA specs | CC-BY 4.0 | Full text |
| OpenTitan documentation | Apache 2.0 | Full text |
| Zephyr RTOS documentation | Apache 2.0 | Full text |
| Devicetree Specification | BSD | Full text |
| Linux kernel `Documentation/arch/arm64` | GPL-2.0 w/ docs exception | Full text |
| Raspberry Pi BCM2711 datasheet | Open publication | Full text |
| ESP32 technical reference manual | Open publication | Full text |
| ~15–20 open-access arXiv papers | Varies — per-paper check | Indexed + cited only |
| 5–10 public industry blog posts | All rights reserved | Indexed + cited only |

---

## 2. Excluded sources

Anything considered and rejected, with the reason. This list is as important as the inclusion
list — it demonstrates the licence gate actually rejected things.

| Source | Reason for exclusion | Date |
|---|---|---|
| — | — | — |

---

## 3. Private-only corpus (M11, optional)

**Not part of any public deployment.**

| Source | Licence | Restriction |
|---|---|---|
| Arm Architecture Reference Manual | Arm free developer licence | Personal/development use only. Never committed to git. Never written to a bucket used by a public deployment. Reachable only via SSH tunnel or `make run-local` against a private VPC. |

The guardrail is technical, not documentary: the Terraform for this instance refuses to apply
if its resources would receive a public-facing load balancer, a CloudFront distribution, or a
security group with a public CIDR. Verified at M11 by deliberately attempting a public deploy
and confirming the failure.
