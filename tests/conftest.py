"""Shared fixtures."""

import pytest
from fastapi.testclient import TestClient

from service.main import app


@pytest.fixture
def client() -> TestClient:
    return TestClient(app)
