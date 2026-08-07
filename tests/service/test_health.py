"""Tests for the /health endpoint."""

import re

import pytest
from fastapi.testclient import TestClient

from service.main import app


def test_health_200(client: TestClient) -> None:
    response = client.get("/health")
    assert response.status_code == 200

    body = response.json()
    assert body["status"] == "ok"
    assert body["service"] == "specsage"
    assert {"version", "git_sha", "environment"} <= body.keys()


def test_health_reports_git_sha(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("GIT_SHA", "abc1234")
    with TestClient(app) as c:
        assert c.get("/health").json()["git_sha"] == "abc1234"


def test_health_degrades_gracefully_without_git_sha(monkeypatch: pytest.MonkeyPatch) -> None:
    """A health endpoint that 500s because it can't identify itself is worse than one that
    admits it doesn't know. Absent GIT_SHA must degrade, not raise."""
    monkeypatch.delenv("GIT_SHA", raising=False)
    with TestClient(app) as c:
        response = c.get("/health")
        assert response.status_code == 200
        assert response.json()["git_sha"] == "unknown"


# Shapes that must never appear in a public response body. Not exhaustive — a tripwire for
# the specific mistake of interpolating config into a diagnostic endpoint.
SECRET_PATTERNS = [
    re.compile(r"AKIA[0-9A-Z]{16}"),  # AWS access key id
    re.compile(r"ASIA[0-9A-Z]{16}"),  # AWS temporary access key id
    re.compile(r"aws_secret_access_key", re.I),
    re.compile(r"\bsk-[A-Za-z0-9_-]{20,}"),  # generic provider api key
    re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----"),
]


def test_health_leaks_no_secrets(client: TestClient) -> None:
    body = client.get("/health").text
    for pattern in SECRET_PATTERNS:
        assert not pattern.search(body), f"/health response matched {pattern.pattern}"
