"""S3 upload — idempotent by content hash.

The ingestion task is expected to be re-run: on a schedule, after a failure, or because
someone wants to check whether upstream changed. Re-uploading 7.6 MB every time is cheap, but
it churns object versions in a versioned bucket and destroys the one signal worth having —
"did this document actually change since last time?"

So each object carries its SHA256 as user metadata, and an upload is skipped when the remote
hash already matches. The result is that a no-op run produces zero new versions, and any new
version in the bucket means the upstream document genuinely changed.

**Why not use ETag?** For a single-part upload ETag is the MD5, but boto3 switches to
multipart above a threshold and the ETag becomes a hash-of-hashes with a `-N` suffix. Content
identity that silently changes meaning at an arbitrary size boundary is not content identity.
"""

from __future__ import annotations

import logging
from dataclasses import dataclass
from pathlib import Path

import boto3
from botocore.exceptions import ClientError

from ingestion.fetch import FetchedDoc

log = logging.getLogger(__name__)

SHA_METADATA_KEY = "sha256"


@dataclass(frozen=True, slots=True)
class UploadResult:
    key: str
    uploaded: bool  # False = skipped, remote already matched
    size_bytes: int


class Storage:
    """S3 writes for the raw corpus.

    Deliberately not a general-purpose S3 wrapper. It knows one key layout and one
    idempotency rule, which is what makes the ingestion job's behaviour predictable.
    """

    def __init__(self, bucket: str, prefix: str = "raw", client=None) -> None:
        self.bucket = bucket
        self.prefix = prefix.strip("/")
        self._s3 = client or boto3.client("s3")

    def key_for(self, source_id: str, filename: str) -> str:
        return f"{self.prefix}/{source_id}/{filename}"

    def remote_sha(self, key: str) -> str | None:
        """The stored SHA256, or None if the object is absent."""
        try:
            head = self._s3.head_object(Bucket=self.bucket, Key=key)
        except ClientError as e:
            if e.response["Error"]["Code"] in ("404", "NoSuchKey", "NotFound"):
                return None
            raise
        return head.get("Metadata", {}).get(SHA_METADATA_KEY)

    def put_document(self, doc: FetchedDoc) -> UploadResult:
        key = self.key_for(doc.source.id, doc.filename)

        if self.remote_sha(key) == doc.sha256:
            log.info("unchanged, skipping upload: %s", key)
            return UploadResult(key=key, uploaded=False, size_bytes=doc.size_bytes)

        # Provenance travels with the object. If the manifest is ever lost or someone finds a
        # stray file in the bucket, the licence and origin are readable from the object itself
        # rather than only from a YAML file elsewhere.
        metadata = {
            SHA_METADATA_KEY: doc.sha256,
            "source-id": doc.source.id,
            "licence": doc.licence,
            "source-url": doc.url[:1024],
        }

        with doc.path.open("rb") as fh:
            self._s3.put_object(
                Bucket=self.bucket,
                Key=key,
                Body=fh,
                Metadata=metadata,
                ContentType=_content_type(doc.filename),
            )
        log.info("uploaded %s (%d bytes)", key, doc.size_bytes)
        return UploadResult(key=key, uploaded=True, size_bytes=doc.size_bytes)

    def put_text(self, key: str, body: str, content_type: str) -> None:
        self._s3.put_object(
            Bucket=self.bucket,
            Key=f"{self.prefix}/{key}" if not key.startswith(self.prefix) else key,
            Body=body.encode("utf-8"),
            ContentType=content_type,
        )


def _content_type(filename: str) -> str:
    suffix = Path(filename).suffix.lower()
    return {
        ".pdf": "application/pdf",
        ".rst": "text/x-rst; charset=utf-8",
        ".txt": "text/plain; charset=utf-8",
        ".md": "text/markdown; charset=utf-8",
        ".yaml": "application/yaml",
        ".yml": "application/yaml",
    }.get(suffix, "application/octet-stream")
