"""Build identity — version, git SHA, and environment.

Kept separate from `settings` because this is baked in at image-build time (via a Docker
build arg) rather than configured at runtime. Conflating the two makes it possible to deploy
an image that misreports which commit it contains, which defeats the smoke test.
"""

import os

from service.settings import settings

UNKNOWN = "unknown"


def git_sha() -> str:
    """The commit this build was made from.

    Returns `"unknown"` rather than raising when the variable is absent — a health endpoint
    that 500s because it can't identify itself is worse than one that admits it doesn't know.
    Local `make run-local` passes the real SHA; the container bakes it in at build time.
    """
    return os.environ.get("GIT_SHA") or UNKNOWN


def build_info() -> dict[str, str]:
    return {
        "status": "ok",
        "service": "specsage",
        "version": settings.version,
        "git_sha": git_sha(),
        "environment": settings.environment,
    }
