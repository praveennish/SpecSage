"""The source registry — declarative, one entry per document.

Adding a source means adding a row here. Nothing else in the pipeline knows what the corpus
contains, which is what keeps the licence gate meaningful: there is exactly one place a
document can enter, and it cannot enter without naming a licence.

**Selection rationale** (approved 2026-08-23, recorded in DECISION-LOG):

  Tier A + BCM2711 + CC-BY arXiv papers. Skipped: OpenTitan, Zephyr, ESP32, all blogs.

  Policy (revised 2026-08-23): verified-redistributable ONLY. No index-only tier. Anything
  whose licence does not explicitly permit redistribution is not ingested at all.

  - All four structural types are represented — ISA spec, kernel doc, datasheet, paper —
    because M2's chunking tests need 2-3 sample pages per *type*, and the types differ
    structurally in ways one heuristic will not cover.
  - Graph density is concentrated in the ISA specs, where "see Section X.Y" cross-references
    are thickest. That is what makes M4's reference graph worth building.
  - ESP32's technical reference manual is ~1,000 pages — roughly 45% of the corpus for one
    more instance of a type BCM2711 already covers. Worst pages-per-insight on the list.
  - OpenTitan and Zephyr are Apache-2.0 and trivially appendable if the corpus feels thin
    after M3.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from enum import StrEnum


class DocType(StrEnum):
    """Structural shape. Drives M2's chunking strategy, not just metadata.

    These four parse very differently: an ISA spec has deep numbered sections and pseudocode
    blocks; a datasheet is dominated by register tables; kernel docs are reStructuredText
    with no page concept at all; papers have two-column layout and dense citations.
    """

    ISA_SPEC = "isa_spec"
    DATASHEET = "datasheet"
    KERNEL_DOC = "kernel_doc"
    PAPER = "paper"
    BLOG = "blog"


class FetchKind(StrEnum):
    """How to retrieve it. Not every source is a single PDF at a stable URL."""

    PDF = "pdf"
    GITHUB_RELEASE_ASSET = "github_release_asset"
    GITHUB_TREE = "github_tree"  # a directory of text files
    ARXIV_QUERY = "arxiv_query"  # resolved at fetch time via the arXiv API


@dataclass(frozen=True, slots=True)
class Source:
    id: str
    title: str
    doc_type: DocType
    fetch_kind: FetchKind
    licence: str
    publisher: str
    url: str
    licence_url: str | None = None
    est_pages: int | None = None
    # GITHUB_TREE only
    repo: str | None = None
    path: str | None = None
    asset_pattern: str | None = None  # GITHUB_RELEASE_ASSET: exact asset name
    # PINNING. Empty means "track upstream", which is the wrong default for a corpus whose
    # golden set (M7) is keyed to section numbers: if the document shifts underneath, the
    # evaluation silently rots and reports a number for a corpus that no longer exists.
    #
    # This is not hypothetical. RISC-V cut a new release two days into M1 and riscv-spec.pdf
    # changed by 118 bytes between two runs a week apart.
    #
    # The fetcher still queries `latest` and LOGS when it differs from the pin, so pinning
    # buys reproducibility without buying silence. Bumping a pin is then a deliberate commit
    # that shows up in review, alongside whatever golden-set changes it forces.
    release_tag: str | None = None  # GITHUB_RELEASE_ASSET
    ref: str | None = None  # GITHUB_TREE: branch, tag, or commit SHA
    suffixes: tuple[str, ...] = ()
    # ARXIV_QUERY only
    query: str | None = None
    max_results: int = 0  # how many records to SCAN
    target_count: int = 0  # how many redistributable ones we want to KEEP
    notes: str = ""
    tags: tuple[str, ...] = field(default_factory=tuple)


# --------------------------------------------------------------------------- Tier A

# The RISC-V manual ships as a SINGLE combined PDF, not the separate Unprivileged/Privileged
# volumes the original plan assumed. Verified 2026-08-24 against the latest release
# (riscv-isa-release-b2cdb58-2026-08-23): the only PDF asset is `riscv-spec.pdf`, 5.5 MB.
#
# This is why the registry names an asset explicitly rather than deriving a filename from the
# source id — upstream release layouts change, and a guessed filename fails at fetch time with
# a 404 that looks like a network problem.
RISCV_ISA_MANUAL = Source(
    id="riscv-isa-manual",
    title="RISC-V Instruction Set Manual (Unprivileged + Privileged)",
    doc_type=DocType.ISA_SPEC,
    fetch_kind=FetchKind.GITHUB_RELEASE_ASSET,
    licence="CC-BY-4.0",
    licence_url="https://github.com/riscv/riscv-isa-manual/blob/main/LICENSE",
    publisher="RISC-V International",
    url="https://github.com/riscv/riscv-isa-manual",
    repo="riscv/riscv-isa-manual",
    asset_pattern="riscv-spec.pdf",
    release_tag="riscv-isa-release-07531fd-2026-08-24",
    est_pages=700,
    notes="Densest cross-reference source in the corpus. Primary M4 graph material.",
    tags=("riscv", "isa"),
)

DEVICETREE_SPEC = Source(
    id="devicetree-spec",
    title="Devicetree Specification",
    doc_type=DocType.ISA_SPEC,
    fetch_kind=FetchKind.GITHUB_RELEASE_ASSET,
    licence="BSD-2-Clause",
    licence_url="https://github.com/devicetree-org/devicetree-specification/blob/main/LICENSE",
    publisher="devicetree.org",
    url="https://github.com/devicetree-org/devicetree-specification",
    repo="devicetree-org/devicetree-specification",
    asset_pattern="devicetree-specification-v*.pdf",
    release_tag="v0.4",
    est_pages=120,
    notes="Clean numbered sections — a good control against the messier RISC-V layout.",
    tags=("devicetree",),
)

LINUX_ARM64_DOCS = Source(
    id="linux-arm64-docs",
    title="Linux Kernel Documentation — arch/arm64",
    doc_type=DocType.KERNEL_DOC,
    fetch_kind=FetchKind.GITHUB_TREE,
    licence="GPL-2.0-with-docs-exception",
    licence_url="https://www.kernel.org/doc/html/latest/process/license-rules.html",
    publisher="Linux kernel community",
    url="https://github.com/torvalds/linux/tree/master/Documentation/arch/arm64",
    repo="torvalds/linux",
    path="Documentation/arch/arm64",
    suffixes=(".rst", ".txt"),
    ref="v7.2",  # a kernel release tag, not `master` — see release_tag above
    est_pages=40,
    notes="reStructuredText, no page concept. Forces M2 to handle a non-paginated type.",
    tags=("linux", "arm64"),
)

# --------------------------------------------------------------------------- Tier C (partial)

BCM2711_PERIPHERALS = Source(
    id="bcm2711-peripherals",
    title="BCM2711 ARM Peripherals",
    doc_type=DocType.DATASHEET,
    fetch_kind=FetchKind.PDF,
    licence="OPEN-PUBLICATION",
    licence_url="https://www.raspberrypi.com/documentation/computers/processors.html",
    publisher="Raspberry Pi Ltd",
    url="https://datasheets.raspberrypi.com/bcm2711/bcm2711-peripherals.pdf",
    est_pages=200,
    notes="Register-table-dominated. The datasheet archetype; chunking must not split tables.",
    tags=("broadcom", "soc"),
)

# --------------------------------------------------------------------------- Tier D

# Resolved at fetch time against the arXiv API rather than pinned to IDs chosen in advance.
#
# Two reasons. Pinning IDs means asserting papers exist and are relevant without having read
# them. And the arXiv API returns each paper's actual licence per-record, which is the only
# reliable way to tell a CC-BY paper from one under arXiv's default non-exclusive licence —
# a distinction that decides FULL_TEXT vs INDEX_ONLY and cannot be guessed from the abstract.
ARXIV_COMPUTER_ARCHITECTURE = Source(
    id="arxiv-computer-architecture",
    title="Open-licensed computer-architecture papers (arXiv cs.AR)",
    doc_type=DocType.PAPER,
    fetch_kind=FetchKind.ARXIV_QUERY,
    # Papers are FILTERED, not declared. The API returns each paper's actual licence; only
    # CC-BY / CC-BY-SA / CC0 records are ingested and the rest are skipped with a count.
    #
    # This field is the FLOOR, not a claim about what will be fetched: arXiv's default
    # submission licence grants arXiv the right to distribute and grants the reader nothing.
    # Declaring it here documents what an unfiltered fetch would be, and guarantees that a
    # bug in the filter cannot silently admit non-open papers — assert_redistributable()
    # would reject this value outright.
    licence="ARXIV-PERPETUAL-NONEXCLUSIVE",
    licence_url="https://arxiv.org/licenses/nonexclusive-distrib/1.0/",
    publisher="arXiv",
    url="https://arxiv.org",
    query="cat:cs.AR",
    # Scanned, not taken. Expect a minority of cs.AR papers to carry an open licence, so the
    # scan window is deliberately wide. The fetcher reports the yield ratio: if it comes back
    # under ~8 usable papers, that is a finding — the corpus loses its fourth structural type
    # and M2's chunker goes untested against two-column layout.
    max_results=200,
    target_count=18,
    est_pages=200,
    notes=(
        "Fourth structural type: two-column, dense inline citations, no numbered-section "
        "hierarchy. Nothing else in the corpus parses like this. CC-BY only."
    ),
    tags=("arxiv", "papers"),
)

# DEFERRED from the initial fetch — not dropped. Reason, verified 2026-08-24:
#
#   * The arXiv Atom API (export.arxiv.org/api/query) returns 200 but exposes NO licence
#     field. Entry elements are id/title/summary/author/category/arxiv:primary_category/
#     arxiv:comment/link/published/updated. The string "license" appears nowhere.
#   * Per-paper licence lives only in OAI-PMH arXivRaw metadata. That endpoint MOVED:
#     export.arxiv.org/oai2 now 301s to oaipmh.arxiv.org/oai, which did not respond within
#     90s from the development network.
#
# Under a verified-redistributable-only policy, a source whose licence cannot be read is a
# source that cannot be ingested. Rather than guess, the resolver is implemented and exercised
# from the Fargate task, whose egress differs from a laptop. If OAI-PMH is reachable there,
# arXiv is added in a follow-up run; if not, the corpus loses its fourth structural type and
# that becomes an M2 finding rather than a silent gap.

# Industry blogs are OMITTED.
#
# All-rights-reserved by default, so they cannot be redistributed under the verified-only
# policy — and unlike papers they contribute no structural type the corpus lacks. Cheap to
# lose. If a specific post ever carries an explicit open licence, add it as a normal Source.

# --------------------------------------------------------------------------- registry

SOURCES: list[Source] = [
    RISCV_ISA_MANUAL,
    DEVICETREE_SPEC,
    LINUX_ARM64_DOCS,
    BCM2711_PERIPHERALS,
]

# Halts the job if the real corpus exceeds this. Estimates in this file are estimates; a
# source turning out to be five times larger than expected would silently inflate M3
# embedding spend and M4's per-chunk LLM extraction cost. Fail loudly instead.
PAGE_CEILING = 1_500


def by_id(source_id: str) -> Source:
    for s in SOURCES:
        if s.id == source_id:
            return s
    raise KeyError(f"no source with id {source_id!r}")


def estimated_pages() -> int:
    return sum(s.est_pages or 0 for s in SOURCES)
