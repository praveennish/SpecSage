"""Registry invariants — the build gate applied to the source list itself.

This is the test that actually fails a PR. `test_licences.py` proves the gate works;
this proves it is pointed at the real registry, so a source added without a resolvable
licence cannot merge.
"""

import pytest

from ingestion.licences import LicenceError, assert_redistributable
from ingestion.sources import PAGE_CEILING, SOURCES, DocType, FetchKind, Source, estimated_pages


@pytest.mark.parametrize("source", SOURCES, ids=lambda s: s.id)
def test_every_source_has_a_redistributable_licence(source: Source) -> None:
    """THE build gate. If this fails, a source was added that cannot legally be republished.

    Do not fix it by widening REDISTRIBUTABLE. Fix it by reading the licence and either
    removing the source or adding the licence after confirming its terms.
    """
    assert_redistributable(source.licence, licence_url=source.licence_url)


def test_source_ids_are_unique() -> None:
    """IDs become S3 key prefixes; a duplicate silently overwrites another source's corpus."""
    ids = [s.id for s in SOURCES]
    assert len(ids) == len(set(ids)), f"duplicate source ids: {sorted(set(ids))}"


@pytest.mark.parametrize("source", SOURCES, ids=lambda s: s.id)
def test_source_id_is_safe_as_an_s3_prefix(source: Source) -> None:
    assert source.id
    assert "/" not in source.id
    assert source.id == source.id.strip()
    assert source.id.replace("-", "").replace("_", "").isalnum()


@pytest.mark.parametrize("source", SOURCES, ids=lambda s: s.id)
def test_fetch_kind_has_the_fields_it_needs(source: Source) -> None:
    """Each fetch strategy needs different fields; a missing one fails at runtime otherwise.

    Catching it here means a malformed registry entry fails a PR rather than a Fargate task
    twenty seconds into a run.
    """
    if source.fetch_kind is FetchKind.GITHUB_RELEASE_ASSET:
        assert source.repo, f"{source.id}: needs repo"
        assert source.asset_pattern, f"{source.id}: needs asset_pattern"
    elif source.fetch_kind is FetchKind.GITHUB_TREE:
        assert source.repo, f"{source.id}: needs repo"
        assert source.path, f"{source.id}: needs path"
        assert source.suffixes, f"{source.id}: needs suffixes, or it will fetch the whole tree"
    elif source.fetch_kind is FetchKind.PDF:
        assert source.url.startswith("https://"), f"{source.id}: url must be https"
    elif source.fetch_kind is FetchKind.ARXIV_QUERY:
        assert source.query, f"{source.id}: needs query"


@pytest.mark.parametrize("source", SOURCES, ids=lambda s: s.id)
def test_urls_are_https(source: Source) -> None:
    """Plaintext HTTP would let a network attacker substitute corpus content."""
    assert source.url.startswith("https://")
    if source.licence_url:
        assert source.licence_url.startswith("https://")


def test_estimated_pages_are_under_the_ceiling() -> None:
    """A registry that cannot possibly pass the runtime ceiling should fail at PR time."""
    assert estimated_pages() <= PAGE_CEILING


def test_corpus_covers_multiple_structural_types() -> None:
    """M2's chunking tests need 2-3 sample pages per document TYPE.

    Types parse very differently — an ISA spec has deep numbered sections, a datasheet is
    register tables, kernel docs are reStructuredText with no page concept. A single-type
    corpus would let a chunking heuristic look correct while being overfitted.

    Three is the current floor. The paper type (two-column, dense citations) is absent because
    arXiv ingestion is deferred; see sources.py. If that is resolved, raise this to 4.
    """
    types = {s.doc_type for s in SOURCES}
    assert len(types) >= 3, (
        f"only {len(types)} structural type(s): {sorted(t.value for t in types)}"
    )


def test_no_source_declares_a_licence_it_cannot_evidence() -> None:
    """OPEN-PUBLICATION without a URL is a guess wearing a licence's clothes."""
    for s in SOURCES:
        if s.licence.upper() == "OPEN-PUBLICATION":
            assert s.licence_url, f"{s.id}: OPEN-PUBLICATION needs licence_url as evidence"


def test_adding_an_unlicensed_source_would_fail_the_build() -> None:
    """Proves the gate would actually catch a bad addition.

    Without this, every test above could pass on a registry that happens to be clean while the
    enforcement itself is broken — testing the current state rather than the rule.
    """
    bad = Source(
        id="unlicensed-thing",
        title="Something someone found on the internet",
        doc_type=DocType.BLOG,
        fetch_kind=FetchKind.PDF,
        licence="unknown",
        publisher="?",
        url="https://example.com/thing.pdf",
    )
    with pytest.raises(LicenceError):
        assert_redistributable(bad.licence, licence_url=bad.licence_url)


@pytest.mark.parametrize(
    "source",
    [s for s in SOURCES if s.fetch_kind is FetchKind.GITHUB_RELEASE_ASSET],
    ids=lambda s: s.id,
)
def test_github_releases_are_pinned(source: Source) -> None:
    """Corpus reproducibility. Tracking `latest` lets a document change under M7's golden set.

    RISC-V cut a new release two days into M1 and riscv-spec.pdf changed by 118 bytes between
    two runs a week apart. A golden set keyed to section numbers would have silently drifted.
    """
    assert source.release_tag, (
        f"{source.id}: pin release_tag. Tracking `latest` means the corpus can change "
        f"without a commit, which invalidates evaluation keyed to section numbers."
    )


@pytest.mark.parametrize(
    "source",
    [s for s in SOURCES if s.fetch_kind is FetchKind.GITHUB_TREE],
    ids=lambda s: s.id,
)
def test_github_trees_are_pinned(source: Source) -> None:
    """Same argument, and `master` is the worst case — it moves several times a day."""
    assert source.ref, f"{source.id}: pin ref to a tag or commit, not the default branch"
    assert source.ref != "master", f"{source.id}: `master` is not a pin"
