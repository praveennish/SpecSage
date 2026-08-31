"""The licence gate — M1's headline deliverable.

The brief asks for "a unit test that fails the build if any manifest entry lacks a resolvable
license field". These are those tests, plus the cases that make the gate meaningful rather
than decorative: the difference between "we checked and it is restricted" and "we did not
check", and the asymmetry between declared and discovered sources.
"""

import pytest

from ingestion.licences import (
    KNOWN_NON_REDISTRIBUTABLE,
    REDISTRIBUTABLE,
    LicenceError,
    assert_redistributable,
    canonicalise,
    is_redistributable,
)

# --------------------------------------------------------------------------- declared sources


@pytest.mark.parametrize("licence", sorted(REDISTRIBUTABLE - {"OPEN-PUBLICATION"}))
def test_redistributable_licences_are_accepted(licence: str) -> None:
    assert assert_redistributable(licence) == licence


@pytest.mark.parametrize("licence", sorted(KNOWN_NON_REDISTRIBUTABLE))
def test_known_restricted_licences_are_rejected(licence: str) -> None:
    """Recognised but restricted must fail loudly, not degrade quietly.

    There is no index-only tier. A source under CC-BY-NC cannot be ingested at all, and the
    error must say so rather than producing a vaguer "unrecognised".
    """
    with pytest.raises(LicenceError, match="does not permit redistribution"):
        assert_redistributable(licence)


@pytest.mark.parametrize(
    "value", ["", "  ", "unknown", "none", "n/a", "TBD", "?", "unclear", "public", "free"]
)
def test_non_answers_are_rejected(value: str) -> None:
    """Values that look like an answer but are not one.

    "public" and "free" are the dangerous entries here — both read as permissive and neither
    is a licence. Freely readable is not freely redistributable, which is the single most
    common licensing mistake in corpus building.
    """
    with pytest.raises(LicenceError, match="not an answer"):
        assert_redistributable(value)


def test_missing_licence_is_rejected() -> None:
    with pytest.raises(LicenceError, match="missing"):
        assert_redistributable(None)


def test_unrecognised_licence_is_rejected_not_guessed() -> None:
    """An unknown licence must never be assumed permissive.

    The error tells you to read the terms and add it to one of the two sets, because the only
    correct action is a human decision.
    """
    with pytest.raises(LicenceError, match="not recognised"):
        assert_redistributable("WTFPL")


def test_open_publication_requires_evidence() -> None:
    """OPEN-PUBLICATION is a judgement, not a standard licence.

    Vendor datasheets often carry no SPDX identifier but are clearly published for public use.
    Accepting that claim without a URL makes it indistinguishable from a guess, so the URL is
    mandatory — it is what an auditor would follow.
    """
    with pytest.raises(LicenceError, match="requires licence_url"):
        assert_redistributable("OPEN-PUBLICATION")

    assert (
        assert_redistributable("OPEN-PUBLICATION", licence_url="https://example.com/terms")
        == "OPEN-PUBLICATION"
    )


@pytest.mark.parametrize("spelling", ["cc-by-4.0", "CC-BY-4.0", "Cc-By-4.0", "  CC-BY-4.0  "])
def test_licence_matching_is_case_and_whitespace_insensitive(spelling: str) -> None:
    """Upstream metadata is inconsistent about case; a correct licence should not fail on it."""
    assert assert_redistributable(spelling) == "CC-BY-4.0"


# --------------------------------------------------------------------------- discovered sources


@pytest.mark.parametrize("licence", sorted(REDISTRIBUTABLE - {"OPEN-PUBLICATION"}))
def test_discovered_redistributable_is_kept(licence: str) -> None:
    assert is_redistributable(licence) is True


@pytest.mark.parametrize(
    "licence",
    [*sorted(KNOWN_NON_REDISTRIBUTABLE), "WTFPL", "unknown", "", None],
)
def test_discovered_non_redistributable_is_skipped_not_raised(licence: str | None) -> None:
    """Discovered sources fail silently by design.

    An arXiv paper under a restrictive licence is a normal result, not a mistake — skipping it
    is correct behaviour. Raising here would abort a 200-record scan because one paper was
    restricted, which is exactly backwards.
    """
    assert is_redistributable(licence) is False


def test_discovered_open_publication_without_evidence_is_skipped() -> None:
    assert is_redistributable("OPEN-PUBLICATION") is False
    assert is_redistributable("OPEN-PUBLICATION", licence_url="https://x/terms") is True


def test_the_two_entry_points_disagree_only_in_how_they_fail() -> None:
    """The asymmetry is the design, so it is asserted rather than left implicit.

    Same verdict, different consequence: a declared source that fails is a mistake someone
    made and should stop the build; a discovered one is data and should be filtered.
    """
    for licence in ["ARR", "WTFPL", "unknown"]:
        assert is_redistributable(licence) is False
        with pytest.raises(LicenceError):
            assert_redistributable(licence)


# --------------------------------------------------------------------------- invariants


def test_the_two_sets_do_not_overlap() -> None:
    """A licence in both sets would make the gate's verdict depend on lookup order."""
    assert not (REDISTRIBUTABLE & KNOWN_NON_REDISTRIBUTABLE)


def test_canonicalise_returns_none_for_unknown() -> None:
    assert canonicalise("WTFPL") is None
    assert canonicalise(None) is None
    assert canonicalise("CC-BY-4.0") == "CC-BY-4.0"


def test_arxiv_default_licence_is_treated_as_restricted() -> None:
    """The specific trap this module exists to prevent.

    arXiv's default submission licence grants *arXiv* the right to distribute and grants the
    reader nothing. Papers under it are free to read and not free to republish. If this test
    ever fails, the corpus has started ingesting papers it may not redistribute.
    """
    assert "ARXIV-PERPETUAL-NONEXCLUSIVE" in KNOWN_NON_REDISTRIBUTABLE
    assert is_redistributable("ARXIV-PERPETUAL-NONEXCLUSIVE") is False
