"""Retrieval — download, hash, and count pages, without trusting the network.

Design constraints, in priority order:

1. **Stream, never buffer.** The RISC-V manual is 5.5 MB today and could be 50 MB after a
   revision. Reading a response into memory to hash it means the peak footprint is the
   largest document, which is a Fargate task sizing decision made accidentally by a library
   call. Bytes go to disk as they arrive and the SHA256 is computed on the way past.

2. **Retry the retryable, fail fast on the rest.** 429 and 5xx are transient; 404 means the
   upstream layout changed and no amount of waiting fixes it. Retrying a 404 turns a clear
   "the asset was renamed" into a slow timeout that reads like a network fault.

3. **Honour Retry-After.** Several of these hosts publish it. Ignoring it and backing off on
   our own schedule is how a polite client becomes a blocked one.

4. **Identify ourselves.** A generic user agent is how you get rate-limited by hosts that are
   otherwise happy to serve you.

docs/PATTERNS.md P-11 (Retry with Exponential Backoff and Jitter).
"""

from __future__ import annotations

import fnmatch
import hashlib
import random
import time
from dataclasses import dataclass
from pathlib import Path

import httpx

from ingestion.licences import assert_redistributable
from ingestion.sources import FetchKind, Source

USER_AGENT = "SpecSage/0.1 (+https://github.com/praveennish/SpecSage) portfolio-project"

# Generous. These are multi-megabyte PDFs from hosts that occasionally think about it, and a
# batch job has no user waiting on it.
TIMEOUT = httpx.Timeout(connect=15.0, read=120.0, write=30.0, pool=15.0)

MAX_ATTEMPTS = 5
BASE_BACKOFF = 2.0
MAX_BACKOFF = 60.0

RETRYABLE_STATUS = frozenset({408, 425, 429, 500, 502, 503, 504})


class FetchError(RuntimeError):
    """Retrieval failed in a way retrying will not fix."""


@dataclass(frozen=True, slots=True)
class FetchedDoc:
    """One retrieved file, on local disk, with its provenance already resolved."""

    source: Source
    filename: str
    path: Path
    sha256: str
    size_bytes: int
    url: str
    licence: str
    licence_url: str | None
    pages: int | None = None


def _client() -> httpx.Client:
    return httpx.Client(
        timeout=TIMEOUT,
        follow_redirects=True,
        headers={"User-Agent": USER_AGENT},
    )


def _sleep_for(attempt: int, response: httpx.Response | None) -> float:
    """Backoff duration, preferring the server's own instruction.

    Jitter matters even for a single-threaded job: without it, a retry storm across the
    handful of documents we fetch lands in lockstep, which is exactly the pattern rate
    limiters are built to punish.
    """
    if response is not None:
        retry_after = response.headers.get("retry-after")
        if retry_after:
            try:
                return min(float(retry_after), MAX_BACKOFF)
            except ValueError:
                pass  # HTTP-date form; fall through to exponential
    return min(BASE_BACKOFF * (2**attempt), MAX_BACKOFF) * (0.5 + random.random())


def _get_json(client: httpx.Client, url: str) -> dict | list:
    for attempt in range(MAX_ATTEMPTS):
        try:
            r = client.get(url)
            if r.status_code in RETRYABLE_STATUS:
                if attempt == MAX_ATTEMPTS - 1:
                    raise FetchError(f"{url} still {r.status_code} after {MAX_ATTEMPTS} attempts")
                time.sleep(_sleep_for(attempt, r))
                continue
            r.raise_for_status()
            return r.json()
        except httpx.HTTPStatusError as e:
            # Non-retryable by definition — we already handled the retryable codes above.
            raise FetchError(f"{url} -> {e.response.status_code}") from e
        except httpx.RequestError as e:
            if attempt == MAX_ATTEMPTS - 1:
                raise FetchError(f"{url} unreachable: {e}") from e
            time.sleep(_sleep_for(attempt, None))
    raise FetchError(f"{url} exhausted retries")  # pragma: no cover - loop always returns


def download(client: httpx.Client, url: str, dest: Path) -> tuple[str, int]:
    """Stream `url` to `dest`, returning (sha256, size_bytes).

    Writes to a `.part` file and renames on success, so an interrupted run cannot leave a
    truncated file that looks complete to the next one.
    """
    dest.parent.mkdir(parents=True, exist_ok=True)
    partial = dest.with_suffix(dest.suffix + ".part")

    for attempt in range(MAX_ATTEMPTS):
        digest = hashlib.sha256()
        size = 0
        try:
            with client.stream("GET", url) as r:
                if r.status_code in RETRYABLE_STATUS:
                    if attempt == MAX_ATTEMPTS - 1:
                        raise FetchError(
                            f"{url} still {r.status_code} after {MAX_ATTEMPTS} attempts"
                        )
                    time.sleep(_sleep_for(attempt, r))
                    continue
                r.raise_for_status()
                with partial.open("wb") as fh:
                    for chunk in r.iter_bytes(chunk_size=64 * 1024):
                        fh.write(chunk)
                        digest.update(chunk)
                        size += len(chunk)
        except httpx.HTTPStatusError as e:
            partial.unlink(missing_ok=True)
            raise FetchError(f"{url} -> {e.response.status_code}") from e
        except httpx.RequestError as e:
            partial.unlink(missing_ok=True)
            if attempt == MAX_ATTEMPTS - 1:
                raise FetchError(f"{url} unreachable: {e}") from e
            time.sleep(_sleep_for(attempt, None))
            continue

        if size == 0:
            partial.unlink(missing_ok=True)
            raise FetchError(f"{url} returned an empty body")

        partial.rename(dest)
        return digest.hexdigest(), size

    raise FetchError(f"{url} exhausted retries")  # pragma: no cover


def count_pdf_pages(path: Path) -> int | None:
    """Page count, or None for formats without a page concept.

    Used for the corpus ceiling check. Deliberately non-fatal: a PDF that pypdf cannot parse
    is a real document that M2 will have to deal with, not a reason to abort ingestion.
    """
    if path.suffix.lower() != ".pdf":
        return None
    try:
        from pypdf import PdfReader

        return len(PdfReader(str(path)).pages)
    except Exception:
        return None


# --------------------------------------------------------------------------- resolvers


def _resolve_release_asset(client: httpx.Client, source: Source) -> str:
    """Find a named asset on the latest GitHub release.

    `asset_pattern` is an fnmatch glob, because some projects version the filename
    (`devicetree-specification-v0.4.pdf`) and pinning the exact string would break on every
    release.
    """
    if not source.repo or not source.asset_pattern:
        raise FetchError(f"{source.id}: GITHUB_RELEASE_ASSET needs repo and asset_pattern")

    release = _get_json(client, f"https://api.github.com/repos/{source.repo}/releases/latest")
    assets = release.get("assets", []) if isinstance(release, dict) else []
    names = [a["name"] for a in assets]

    for asset in assets:
        if fnmatch.fnmatch(asset["name"], source.asset_pattern):
            return asset["browser_download_url"]

    raise FetchError(
        f"{source.id}: no asset matching {source.asset_pattern!r} in release "
        f"{release.get('tag_name')!r}. Available: {names}. The upstream release layout "
        f"probably changed — update asset_pattern in ingestion/sources.py."
    )


def _resolve_tree(client: httpx.Client, source: Source) -> list[tuple[str, str]]:
    """List (filename, download_url) for files in a GitHub directory."""
    if not source.repo or not source.path:
        raise FetchError(f"{source.id}: GITHUB_TREE needs repo and path")

    listing = _get_json(
        client, f"https://api.github.com/repos/{source.repo}/contents/{source.path}"
    )
    if not isinstance(listing, list):
        raise FetchError(f"{source.id}: {source.path} is not a directory")

    out = []
    for item in listing:
        if item.get("type") != "file":
            continue
        name = item["name"]
        if source.suffixes and not name.endswith(source.suffixes):
            continue
        out.append((name, item["download_url"]))
    if not out:
        raise FetchError(f"{source.id}: no files matching {source.suffixes} in {source.path}")
    return out


# --------------------------------------------------------------------------- entry point


def fetch_source(source: Source, workdir: Path) -> list[FetchedDoc]:
    """Retrieve every file for one source.

    The licence is asserted BEFORE any bytes are downloaded. Fetching first and validating
    after would mean a restricted document briefly exists on disk — and on a task with an S3
    upload step, "briefly on disk" is one bug away from "in the bucket".
    """
    licence = assert_redistributable(source.licence, licence_url=source.licence_url)
    out: list[FetchedDoc] = []

    with _client() as client:
        if source.fetch_kind is FetchKind.ARXIV_QUERY:
            raise FetchError(
                f"{source.id}: arXiv ingestion is deferred — the Atom API exposes no licence "
                f"field and OAI-PMH moved to oaipmh.arxiv.org. See the note in sources.py."
            )

        if source.fetch_kind is FetchKind.GITHUB_TREE:
            targets = _resolve_tree(client, source)
        elif source.fetch_kind is FetchKind.GITHUB_RELEASE_ASSET:
            url = _resolve_release_asset(client, source)
            targets = [(url.rsplit("/", 1)[-1], url)]
        else:  # PDF
            targets = [(source.url.rsplit("/", 1)[-1], source.url)]

        for filename, url in targets:
            dest = workdir / source.id / filename
            sha, size = download(client, url, dest)
            out.append(
                FetchedDoc(
                    source=source,
                    filename=filename,
                    path=dest,
                    sha256=sha,
                    size_bytes=size,
                    url=url,
                    licence=licence,
                    licence_url=source.licence_url,
                    pages=count_pdf_pages(dest),
                )
            )
    return out
