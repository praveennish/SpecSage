"""Smoke tests — run against a deployed environment, not a local app.

The SHA assertion is the point. A plain 200 check passes when Terraform applied cleanly but
the function is still serving the previous image; comparing the deployed SHA to the commit
that triggered the deploy is what catches it.

    SPECSAGE_URL=https://xxxx.cloudfront.net EXPECTED_GIT_SHA=$(git rev-parse --short HEAD) \
        uv run pytest -m smoke
"""

import os

import httpx
import pytest

pytestmark = pytest.mark.smoke

TIMEOUT = httpx.Timeout(30.0, connect=10.0)


@pytest.fixture(scope="module")
def base_url() -> str:
    url = os.environ.get("SPECSAGE_URL")
    if not url:
        pytest.skip("SPECSAGE_URL not set — nothing deployed to smoke-test")
    return url.rstrip("/")


def test_health_reachable_over_tls(base_url: str) -> None:
    assert base_url.startswith("https://"), "smoke tests must exercise the TLS path"

    response = httpx.get(f"{base_url}/health", timeout=TIMEOUT)
    assert response.status_code == 200
    assert response.json()["status"] == "ok"


def test_deployed_sha_matches_expected(base_url: str) -> None:
    expected = os.environ.get("EXPECTED_GIT_SHA")
    if not expected:
        pytest.skip("EXPECTED_GIT_SHA not set")

    deployed = httpx.get(f"{base_url}/health", timeout=TIMEOUT).json()["git_sha"]
    assert deployed.startswith(expected[:7]), (
        f"deployed SHA {deployed!r} does not match {expected!r} — "
        "the apply succeeded but stale code is still serving"
    )
