"""Ingestion entry point — `python -m ingestion`.

Runs as a one-off ECS Fargate task (D-020) or locally with --dry-run.

Order of operations is deliberate:

    1. assert every declared licence      before any network call
    2. fetch everything to a temp dir     before any upload
    3. check the page ceiling             before any upload
    4. upload, then write the manifest    manifest last, so it never describes a
                                          bucket state that does not exist

Steps 1 and 3 are both fail-closed gates placed ahead of the irreversible step. A restricted
document should never reach disk, and an unexpectedly enormous corpus should never reach S3 —
because the cost of that lands two milestones later in M3 embedding spend and M4's per-chunk
LLM extraction, where it is much harder to attribute.
"""

from __future__ import annotations

import argparse
import datetime as dt
import logging
import sys
import tempfile
from pathlib import Path

from ingestion.fetch import FetchError, fetch_source
from ingestion.licences import LicenceError, assert_redistributable
from ingestion.manifest import Manifest, ManifestEntry
from ingestion.sources import PAGE_CEILING, SOURCES, Source
from ingestion.storage import Storage

log = logging.getLogger("ingestion")

MANIFEST_KEY = "manifest.yaml"


def _configure_logging(verbose: bool) -> None:
    logging.basicConfig(
        level=logging.DEBUG if verbose else logging.INFO,
        format="%(asctime)s %(levelname)-7s %(name)s: %(message)s",
        stream=sys.stdout,
    )


def preflight(sources: list[Source]) -> None:
    """Gate 1 — every declared licence must resolve, before anything is downloaded.

    Fetching first and validating after would mean a restricted document exists on disk, and
    on a task that also uploads to S3 that is one bug away from existing in the bucket.
    """
    failures: list[str] = []
    for s in sources:
        try:
            assert_redistributable(s.licence, licence_url=s.licence_url)
        except LicenceError as e:
            failures.append(f"  {s.id}: {e}")
    if failures:
        raise SystemExit(
            "licence preflight failed — nothing was downloaded:\n" + "\n".join(failures)
        )
    log.info("licence preflight passed for %d source(s)", len(sources))


def enforce_ceiling(total_pages: int) -> None:
    """Gate 2 — halt if the corpus is larger than planned.

    Page counts in sources.py are estimates and were wrong by up to 47% in both directions on
    the first real run. A source that quietly grows fivefold would inflate M3 and M4 costs
    with no signal at ingestion time, which is the wrong milestone to discover it in.
    """
    if total_pages > PAGE_CEILING:
        raise SystemExit(
            f"corpus is {total_pages} pages, ceiling is {PAGE_CEILING}. Nothing uploaded.\n"
            f"Either trim ingestion/sources.py or raise PAGE_CEILING deliberately — and if "
            f"you raise it, budget for M3 embedding and M4 per-chunk extraction."
        )
    log.info("page ceiling ok: %d / %d", total_pages, PAGE_CEILING)


def run(
    *,
    bucket: str | None,
    dry_run: bool,
    write_provenance: Path | None,
    workdir: Path,
) -> int:
    sources = list(SOURCES)
    preflight(sources)

    docs = []
    failed: list[str] = []
    for source in sources:
        try:
            fetched = fetch_source(source, workdir)
        except FetchError as e:
            # One unreachable source should not discard the whole run — but it must be loud
            # and it must make the exit code non-zero.
            log.error("%s: %s", source.id, e)
            failed.append(source.id)
            continue
        for d in fetched:
            log.info(
                "fetched %s/%s (%d bytes, %s pages)",
                source.id,
                d.filename,
                d.size_bytes,
                d.pages if d.pages is not None else "n/a",
            )
        docs.extend(fetched)

    if not docs:
        log.error("nothing fetched")
        return 1

    total_pages = sum(d.pages or 0 for d in docs)
    enforce_ceiling(total_pages)

    now = dt.datetime.now(dt.UTC)
    entries = [
        ManifestEntry(
            source_id=d.source.id,
            title=d.source.title,
            doc_type=d.source.doc_type.value,
            publisher=d.source.publisher,
            url=d.url,
            s3_key=f"raw/{d.source.id}/{d.filename}",
            filename=d.filename,
            licence=d.licence,
            licence_url=d.licence_url,
            retrieved_at=now,
            sha256=d.sha256,
            size_bytes=d.size_bytes,
            pages=d.pages,
            notes=d.source.notes,
        )
        for d in docs
    ]
    manifest = Manifest(generated_at=now, entries=entries)

    log.info(
        "corpus: %d file(s), %.1f MB, %d pages across %d source(s)",
        len(entries),
        manifest.total_bytes / 1_048_576,
        manifest.total_pages,
        len({e.source_id for e in entries}),
    )

    if write_provenance:
        write_provenance.write_text(manifest.to_provenance_markdown(), encoding="utf-8")
        log.info("wrote %s", write_provenance)

    if dry_run:
        log.info("dry run — nothing uploaded")
        (workdir / MANIFEST_KEY).write_text(manifest.to_yaml(), encoding="utf-8")
        log.info("manifest written to %s", workdir / MANIFEST_KEY)
        return 1 if failed else 0

    if not bucket:
        raise SystemExit("--bucket is required unless --dry-run")

    storage = Storage(bucket)
    uploaded = skipped = 0
    for d in docs:
        result = storage.put_document(d)
        uploaded += result.uploaded
        skipped += not result.uploaded

    # Manifest last: it is the record of what is in the bucket, so writing it before the
    # uploads would leave it describing a state that does not exist if an upload fails.
    storage.put_text(MANIFEST_KEY, manifest.to_yaml(), "application/yaml")
    log.info(
        "s3://%s/raw/ — %d uploaded, %d unchanged, manifest written", bucket, uploaded, skipped
    )

    if failed:
        log.error("sources that failed: %s", ", ".join(failed))
        return 1
    return 0


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(prog="python -m ingestion", description=__doc__)
    p.add_argument("--bucket", help="target S3 bucket (required unless --dry-run)")
    p.add_argument("--dry-run", action="store_true", help="fetch and validate, upload nothing")
    p.add_argument(
        "--write-provenance",
        type=Path,
        metavar="PATH",
        help="render docs/PROVENANCE.md from the manifest",
    )
    p.add_argument("--workdir", type=Path, help="keep downloads here instead of a temp dir")
    p.add_argument("-v", "--verbose", action="store_true")
    args = p.parse_args(argv)

    _configure_logging(args.verbose)

    if args.workdir:
        args.workdir.mkdir(parents=True, exist_ok=True)
        return run(
            bucket=args.bucket,
            dry_run=args.dry_run,
            write_provenance=args.write_provenance,
            workdir=args.workdir,
        )

    with tempfile.TemporaryDirectory(prefix="specsage-ingest-") as tmp:
        return run(
            bucket=args.bucket,
            dry_run=args.dry_run,
            write_provenance=args.write_provenance,
            workdir=Path(tmp),
        )


if __name__ == "__main__":
    raise SystemExit(main())
