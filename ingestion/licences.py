"""Licence resolution — the build gate.

**Policy: verified-redistributable or excluded. There is no third category.**

The corpus is served publicly from M10 onward, and quoting source text back to a user is
redistribution. Rather than maintaining two classes of document — quotable and
index-but-never-quote — and risking them being confused eight milestones from now, nothing
enters the corpus unless its licence explicitly permits redistribution with attribution.

The cost is a smaller corpus. The benefit is that the answer path never has to ask whether it
may quote a chunk: if a chunk is in the index, it is quotable. One category, one rule, no
branch to get wrong under pressure.

Two entry points, because sources arrive two ways:

    assert_redistributable()   for DECLARED sources in sources.py. A source someone added by
                               hand without a resolvable licence is a mistake, and mistakes
                               should fail the build.

    is_redistributable()       for DISCOVERED sources — arXiv results, where the licence is
                               only known after querying the API. A non-redistributable paper
                               is not a mistake, it is a normal result. Skip it and count it.

**The trap this exists to prevent:** arXiv papers are not automatically open-licensed. The
default arXiv submission licence grants *arXiv* the right to distribute; it grants the reader
nothing. Free-to-read is not free-to-redistribute, and the two are easy to conflate. Only
papers whose API record names an open licence are ingested.
"""

from __future__ import annotations


class LicenceError(ValueError):
    """A declared source's licence cannot be resolved to something redistributable.

    Deliberately fatal. A declared source with an unnameable licence does not get a
    conservative default — it stops the build, because silently dropping it would let the
    registry and the corpus diverge without anyone noticing.
    """


# Licences that explicitly permit redistribution, given attribution.
#
# SPDX identifiers where one exists, so values are checkable against https://spdx.org/licenses/
# rather than being prose. Two entries are not SPDX and are called out below.
REDISTRIBUTABLE: frozenset[str] = frozenset(
    {
        "CC-BY-4.0",
        "CC-BY-SA-4.0",
        "CC-BY-3.0",
        "CC0-1.0",
        "Apache-2.0",
        "BSD-2-Clause",
        "BSD-3-Clause",
        "MIT",
        # Linux kernel Documentation/ is plain GPL-2.0 — verified: every file under
        # arch/arm64 and arch/x86 carries `SPDX-License-Identifier: GPL-2.0`. There is no
        # "docs exception" making it permissive (an earlier value here implied one); GPL-2.0
        # itself permits verbatim and modified redistribution, and the .rst *is* the source,
        # so the copyleft's source-availability duty is met by shipping the files.
        #
        # It differs from every permissive entry above in one way that matters downstream:
        # it is COPYLEFT. Derivatives SpecSage publishes from these files — quoted chunks in
        # answers, the M7 eval site — must carry GPL-2.0 for the kernel-doc-derived portions.
        # Short attributed quotation (what a RAG citation is) stays well inside that. See
        # DECISION-LOG D-029.
        "GPL-2.0-only",
        # A hardware vendor publishing a datasheet for public use without naming a standard
        # licence. Not SPDX, and a judgement rather than a licence — so it requires
        # `licence_url` evidence. See assert_redistributable().
        "OPEN-PUBLICATION",
    }
)

# Recognised, valid, and NOT redistributable. Naming these explicitly is what separates
# "we checked and it is restricted" from "we did not check" — and it produces a far better
# error message than falling through to "unrecognised".
KNOWN_NON_REDISTRIBUTABLE: frozenset[str] = frozenset(
    {
        "CC-BY-NC-4.0",
        "CC-BY-ND-4.0",
        "CC-BY-NC-ND-4.0",
        "CC-BY-NC-SA-4.0",
        "ARR",  # all rights reserved — the default for blog posts
        "ARXIV-PERPETUAL-NONEXCLUSIVE",  # arXiv's default: the distribution right is arXiv's
    }
)

# Values that look like an answer but are not one. Rejecting them explicitly beats a generic
# "unrecognised licence".
NON_ANSWERS: frozenset[str] = frozenset(
    {"", "unknown", "none", "n/a", "na", "tbd", "todo", "?", "unclear", "public", "free"}
)

_CANONICAL: dict[str, str] = {v.upper(): v for v in REDISTRIBUTABLE | KNOWN_NON_REDISTRIBUTABLE}


def canonicalise(licence: str | None) -> str | None:
    """Normalise a licence string to its canonical spelling, or None if unrecognised.

    SPDX identifiers are case-insensitive in practice, and upstream metadata is inconsistent
    about it — `cc-by-4.0`, `CC-BY-4.0`, and `CC-by-4.0` all appear in the wild.
    """
    if licence is None:
        return None
    normalised = licence.strip()
    if normalised.lower() in NON_ANSWERS:
        return None
    return _CANONICAL.get(normalised.upper())


def is_redistributable(licence: str | None, *, licence_url: str | None = None) -> bool:
    """Non-raising check, for sources DISCOVERED at fetch time.

    Returns False for unrecognised licences as well as recognised-but-restricted ones. That
    conflation is correct here: for a discovered source, "I do not recognise this licence" and
    "this licence forbids redistribution" lead to the same action — skip it. Only a declared
    source deserves an error, because only a declared source implies someone intended it.
    """
    canonical = canonicalise(licence)
    if canonical is None or canonical not in REDISTRIBUTABLE:
        return False
    # OPEN-PUBLICATION is a judgement, not a licence — it needs evidence to count.
    return not (canonical == "OPEN-PUBLICATION" and not licence_url)


def assert_redistributable(licence: str | None, *, licence_url: str | None = None) -> str:
    """Raising check, for sources DECLARED in sources.py. Returns the canonical identifier.

    Raises:
        LicenceError: absent, a non-answer, unrecognised, recognised-but-restricted, or
            OPEN-PUBLICATION without evidence.
    """
    if licence is None:
        raise LicenceError("licence is missing — every declared source must name one")

    normalised = licence.strip()
    if normalised.lower() in NON_ANSWERS:
        raise LicenceError(
            f"licence {licence!r} is not an answer. Name the actual licence. If it does not "
            f"permit redistribution, remove the source — the corpus has no index-only tier."
        )

    canonical = canonicalise(normalised)
    if canonical is None:
        raise LicenceError(
            f"licence {licence!r} is not recognised. After reading the terms, add it to "
            f"REDISTRIBUTABLE or KNOWN_NON_REDISTRIBUTABLE in ingestion/licences.py. "
            f"Do not guess."
        )

    if canonical in KNOWN_NON_REDISTRIBUTABLE:
        raise LicenceError(
            f"licence {canonical!r} does not permit redistribution, and this corpus quotes "
            f"source text in answers. Remove the source."
        )

    if canonical == "OPEN-PUBLICATION" and not licence_url:
        raise LicenceError(
            "OPEN-PUBLICATION requires licence_url as evidence. It is a judgement about a "
            "vendor's publication terms rather than a standard licence, so the claim must be "
            "traceable to a page a human can read."
        )

    return canonical
