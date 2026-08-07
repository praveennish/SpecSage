"""FastAPI application — the HTTP layer.

Deliberately thin. Every endpoint delegates to a library package (`retrieval`, `agents`, …)
so the same logic is reachable from the MCP server (M8) and the eval harness (M7) without
going through HTTP. Nothing that matters should live in this module.

Runs identically in three places: `uvicorn` locally, a container, and AWS Lambda via the
Lambda Web Adapter — the adapter speaks HTTP to this process, so there is no handler shim
and no framework-specific deployment code. See DECISION-LOG D-019.
"""

from fastapi import FastAPI

from service.settings import settings
from service.version import build_info

app = FastAPI(
    title="SpecSage",
    version=settings.version,
    description=(
        "Agentic RAG + knowledge graph over openly-licensed computer-architecture "
        "documentation. Informational only; verify against official specifications."
    ),
)


@app.get("/health", tags=["ops"])
def health() -> dict[str, str]:
    """Liveness probe and deployment fingerprint.

    The `git_sha` field is load-bearing: the deploy workflow asserts it equals the commit
    that triggered the deploy. That is what catches "the apply succeeded but stale code is
    still serving" — a failure mode a plain 200 check misses entirely.
    """
    return build_info()
