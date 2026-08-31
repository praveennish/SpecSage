"""Fetch mechanics — retry, backoff, hashing, and the gate ordering.

No real network. Everything runs against httpx.MockTransport, so these tests are fast,
deterministic, and cannot fail because GitHub is having a bad morning.
"""

from pathlib import Path

import httpx
import pytest

from ingestion import fetch as fetch_mod
from ingestion.fetch import MAX_ATTEMPTS, FetchError, download
from ingestion.licences import LicenceError
from ingestion.sources import DocType, FetchKind, Source


@pytest.fixture(autouse=True)
def no_real_sleeping(monkeypatch: pytest.MonkeyPatch) -> None:
    """Backoff is real seconds. Tests should exercise the logic, not wait it out."""
    monkeypatch.setattr(fetch_mod.time, "sleep", lambda _: None)


def client_returning(*responses: httpx.Response) -> httpx.Client:
    it = iter(responses)

    def handler(request: httpx.Request) -> httpx.Response:
        try:
            return next(it)
        except StopIteration:  # pragma: no cover
            raise AssertionError("more requests than the test provided responses for") from None

    return httpx.Client(transport=httpx.MockTransport(handler))


# --------------------------------------------------------------------------- hashing


def test_download_streams_and_hashes(tmp_path: Path) -> None:
    body = b"hello specsage" * 5000
    dest = tmp_path / "doc.pdf"

    with client_returning(httpx.Response(200, content=body)) as c:
        sha, size = download(c, "https://example.com/doc.pdf", dest)

    import hashlib

    assert sha == hashlib.sha256(body).hexdigest()
    assert size == len(body)
    assert dest.read_bytes() == body


def test_empty_body_is_an_error(tmp_path: Path) -> None:
    """A 200 with no content means something upstream is wrong.

    Treating it as success would put a zero-byte file in the corpus and record a SHA for
    emptiness — which would then look like a legitimate document to every later milestone.
    """
    with (
        client_returning(httpx.Response(200, content=b"")) as c,
        pytest.raises(FetchError, match="empty body"),
    ):
        download(c, "https://example.com/doc.pdf", tmp_path / "doc.pdf")


def test_no_partial_file_survives_a_failure(tmp_path: Path) -> None:
    """Downloads land on a .part file and rename on success.

    An interrupted run must not leave a truncated file that the next run mistakes for a
    complete one — the hash would differ from upstream and nobody would know why.
    """
    dest = tmp_path / "doc.pdf"
    with client_returning(httpx.Response(404)) as c, pytest.raises(FetchError):
        download(c, "https://example.com/doc.pdf", dest)

    assert not dest.exists()
    assert list(tmp_path.glob("*.part")) == []


# --------------------------------------------------------------------------- retry policy


@pytest.mark.parametrize("status", [429, 500, 502, 503, 504])
def test_transient_failures_are_retried(status: int, tmp_path: Path) -> None:
    body = b"eventually fine"
    with client_returning(httpx.Response(status), httpx.Response(200, content=body)) as c:
        _sha, size = download(c, "https://example.com/d.pdf", tmp_path / "d.pdf")
    assert size == len(body)


@pytest.mark.parametrize("status", [400, 401, 403, 404, 410])
def test_permanent_failures_are_not_retried(status: int, tmp_path: Path) -> None:
    """A 404 means the upstream layout changed; waiting cannot fix it.

    This is not just efficiency. Retrying a 404 turns a clear "the asset was renamed" into a
    slow timeout that reads like a network fault — which is exactly how the RISC-V release
    rename would have been misdiagnosed.
    """
    calls = 0

    def handler(_request: httpx.Request) -> httpx.Response:
        nonlocal calls
        calls += 1
        return httpx.Response(status)

    with httpx.Client(transport=httpx.MockTransport(handler)) as c, pytest.raises(FetchError):
        download(c, "https://example.com/d.pdf", tmp_path / "d.pdf")

    assert calls == 1, f"a {status} was retried {calls} times"


def test_retries_are_bounded(tmp_path: Path) -> None:
    calls = 0

    def handler(_request: httpx.Request) -> httpx.Response:
        nonlocal calls
        calls += 1
        return httpx.Response(503)

    with (
        httpx.Client(transport=httpx.MockTransport(handler)) as c,
        pytest.raises(FetchError, match="after"),
    ):
        download(c, "https://example.com/d.pdf", tmp_path / "d.pdf")

    assert calls == MAX_ATTEMPTS


def test_retry_after_header_is_honoured() -> None:
    """Ignoring a server's own backoff instruction is how a polite client becomes a blocked one."""
    r = httpx.Response(429, headers={"retry-after": "7"})
    assert fetch_mod._sleep_for(0, r) == 7.0


def test_backoff_grows_and_is_jittered() -> None:
    """Jitter matters even single-threaded: without it, retries across the handful of
    documents land in lockstep, which is the pattern rate limiters punish."""
    early = [fetch_mod._sleep_for(0, None) for _ in range(20)]
    late = [fetch_mod._sleep_for(4, None) for _ in range(20)]

    assert min(late) > max(early), "backoff should grow with attempt number"
    assert len(set(early)) > 1, "no jitter — retries would synchronise"
    assert max(late) <= fetch_mod.MAX_BACKOFF


# --------------------------------------------------------------------------- gate ordering


def test_licence_is_checked_before_any_network_call(tmp_path: Path) -> None:
    """The ordering that keeps restricted documents off disk entirely.

    Fetching first and validating after would mean a restricted document briefly exists
    locally — and on a task that also uploads to S3, "briefly on disk" is one bug away from
    "in the bucket".
    """
    called = False

    def tripwire(*_args, **_kwargs):  # pragma: no cover - must never run
        nonlocal called
        called = True
        raise AssertionError("network was touched before the licence was validated")

    restricted = Source(
        id="restricted",
        title="Something all-rights-reserved",
        doc_type=DocType.BLOG,
        fetch_kind=FetchKind.PDF,
        licence="ARR",
        publisher="Someone",
        url="https://example.com/post.pdf",
    )

    import unittest.mock

    with (
        unittest.mock.patch.object(fetch_mod, "_client", tripwire),
        pytest.raises(LicenceError),
    ):
        fetch_mod.fetch_source(restricted, tmp_path)

    assert called is False
    assert list(tmp_path.iterdir()) == []


def test_deferred_arxiv_fetch_fails_loudly(tmp_path: Path) -> None:
    """Deferred, not silently skipped.

    A source in the registry that quietly fetches nothing is worse than one that errors — the
    corpus would be missing a structural type and the manifest would look complete.

    Two independent guards would reject this source: the unimplemented fetch kind, and its
    declared licence (deliberately the restrictive arXiv default, so the registry fails closed
    if the CC-BY filter is ever bypassed). The deferred message must win, because it points at
    the actual problem instead of sending you after a licensing issue that is not there.
    """
    from ingestion.sources import ARXIV_COMPUTER_ARCHITECTURE

    with pytest.raises(FetchError, match="deferred"):
        fetch_mod.fetch_source(ARXIV_COMPUTER_ARCHITECTURE, tmp_path)


def test_arxiv_source_would_also_fail_the_licence_gate(tmp_path: Path) -> None:
    """The second guard, asserted directly so removing the first cannot silently open a hole."""
    from ingestion.licences import assert_redistributable
    from ingestion.sources import ARXIV_COMPUTER_ARCHITECTURE as A

    with pytest.raises(LicenceError, match="does not permit redistribution"):
        assert_redistributable(A.licence, licence_url=A.licence_url)


# --------------------------------------------------------------------------- page counting


def test_page_count_is_none_for_non_pdf(tmp_path: Path) -> None:
    p = tmp_path / "doc.rst"
    p.write_text("Section\n=======\n")
    assert fetch_mod.count_pdf_pages(p) is None


def test_unparseable_pdf_does_not_abort_ingestion(tmp_path: Path) -> None:
    """A PDF pypdf cannot read is a real document M2 will have to handle, not a reason to
    stop. It counts as unknown pages rather than killing the run."""
    p = tmp_path / "broken.pdf"
    p.write_bytes(b"%PDF-1.7 this is not actually a pdf")
    assert fetch_mod.count_pdf_pages(p) is None
