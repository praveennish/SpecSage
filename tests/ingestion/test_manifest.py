"""Manifest schema — the durable provenance record.

The manifest outlives the run that produced it. M2, M3, and M4 read it, and it is what an
auditor would ask for. So the licence gate is enforced on the record itself, not only at fetch
time: a hand-edited or corrupted manifest must not be able to introduce an entry the rest of
the pipeline then trusts.
"""

import datetime as dt

import pytest
from pydantic import ValidationError

from ingestion.manifest import Manifest, ManifestEntry

NOW = dt.datetime(2026, 8, 30, 12, 0, tzinfo=dt.UTC)
SHA = "a" * 64


def entry(**overrides) -> ManifestEntry:
    base = dict(
        source_id="riscv-isa-manual",
        title="RISC-V Instruction Set Manual",
        doc_type="isa_spec",
        publisher="RISC-V International",
        url="https://github.com/riscv/riscv-isa-manual",
        s3_key="raw/riscv-isa-manual/riscv-spec.pdf",
        filename="riscv-spec.pdf",
        licence="CC-BY-4.0",
        licence_url="https://github.com/riscv/riscv-isa-manual/blob/main/LICENSE",
        retrieved_at=NOW,
        sha256=SHA,
        size_bytes=5_542_381,
        pages=906,
    )
    return ManifestEntry(**{**base, **overrides})


# --------------------------------------------------------------------------- the gate


def test_entry_with_restricted_licence_is_rejected() -> None:
    """A manifest cannot record something the corpus may not republish."""
    with pytest.raises(ValidationError, match="does not permit redistribution"):
        entry(licence="CC-BY-NC-4.0")


def test_entry_with_unresolvable_licence_is_rejected() -> None:
    with pytest.raises(ValidationError, match="not an answer"):
        entry(licence="unknown")


def test_open_publication_entry_needs_evidence() -> None:
    """Regression test for a real bug.

    A @field_validator on `licence` sees only fields declared BEFORE it — pydantic validates
    in declaration order — so licence_url was absent and OPEN-PUBLICATION was rejected for
    missing evidence it actually had. Fixed with model_validator(mode="after").

    Reordering the two field declarations would also have "fixed" it, and would have left a
    correctness property depending on the order of two lines in a class body. This test exists
    so a future tidy-up cannot silently reintroduce it.
    """
    ok = entry(licence="OPEN-PUBLICATION", licence_url="https://example.com/terms")
    assert ok.licence == "OPEN-PUBLICATION"

    with pytest.raises(ValidationError, match="requires licence_url"):
        entry(licence="OPEN-PUBLICATION", licence_url=None)


# --------------------------------------------------------------------------- schema


def test_sha256_must_be_a_real_digest() -> None:
    for bad in ["", "abc", "A" * 64, "z" * 64, SHA[:63]]:
        with pytest.raises(ValidationError):
            entry(sha256=bad)


def test_size_must_be_positive() -> None:
    """A zero-byte file means the download silently failed."""
    with pytest.raises(ValidationError):
        entry(size_bytes=0)


def test_pages_may_be_absent() -> None:
    """reStructuredText has no page concept. None, not 0.

    Zero would make 27 real Linux docs weightless in the ceiling arithmetic — arguably fine
    here, but wrong in a way that compounds once other paginated formats appear.
    """
    assert entry(pages=None).pages is None


# --------------------------------------------------------------------------- round trip


def test_yaml_round_trip_is_lossless() -> None:
    original = Manifest(generated_at=NOW, entries=[entry(), entry(source_id="devicetree-spec")])
    assert Manifest.from_yaml(original.to_yaml()) == original


def test_round_trip_revalidates_licences() -> None:
    """Reading a manifest re-runs the gate.

    Someone hand-editing manifest.yaml to slip in a restricted source should get a validation
    error on load, not a corpus that quietly contains it.
    """
    m = Manifest(generated_at=NOW, entries=[entry()])
    tampered = m.to_yaml().replace("CC-BY-4.0", "CC-BY-NC-4.0")
    with pytest.raises(ValidationError):
        Manifest.from_yaml(tampered)


def test_totals() -> None:
    m = Manifest(
        generated_at=NOW,
        entries=[entry(pages=906, size_bytes=100), entry(pages=None, size_bytes=50)],
    )
    assert m.total_pages == 906
    assert m.total_bytes == 150


# --------------------------------------------------------------------------- provenance doc


def test_provenance_markdown_is_generated_not_authored() -> None:
    md = Manifest(generated_at=NOW, entries=[entry()]).to_provenance_markdown()
    assert md.startswith("<!-- GENERATED")
    assert "Do not edit by hand" in md


def test_provenance_records_licence_and_hash() -> None:
    """The two facts the document exists to carry."""
    md = Manifest(generated_at=NOW, entries=[entry()]).to_provenance_markdown()
    assert "CC-BY-4.0" in md
    assert SHA in md
    assert "raw/riscv-isa-manual/riscv-spec.pdf" in md


def test_provenance_states_the_policy() -> None:
    """A provenance file that lists sources without stating the rule invites the wrong
    inference — that these are simply the sources someone happened to pick."""
    md = Manifest(generated_at=NOW, entries=[entry()]).to_provenance_markdown()
    assert "Verified-redistributable only" in md


def test_provenance_mentions_the_excluded_arm_manual() -> None:
    """The Arm ARM is licensed for personal use only and must never enter a public deployment.
    Its absence is a deliberate decision and should be visible, not inferred from a gap."""
    md = Manifest(generated_at=NOW, entries=[entry()]).to_provenance_markdown()
    assert "Architecture Reference Manual" in md
