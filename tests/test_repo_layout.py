"""Structural tests.

The build brief asks for every package to be created with a header explaining its purpose,
even when otherwise empty. That discipline decays the moment it stops being checked, so it is
checked. This test is why `docs/ARCHITECTURE.md` can claim the layout is self-documenting.
"""

import ast
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent

PACKAGES = [
    "service",
    "ingestion",
    "embedding",
    "graph",
    "retrieval",
    "agents",
    "eval",
    "mcp_server",
    "finetune",
]

REQUIRED_DOCS = [
    "ARCHITECTURE.md",
    "DECISIONS.md",
    "DECISION-LOG.md",
    "PROVENANCE.md",
    "RUNBOOK.md",
    "COSTS.md",
    "INTERVIEW-NOTES.md",
]


@pytest.mark.parametrize("package", PACKAGES)
def test_package_exists(package: str) -> None:
    assert (REPO_ROOT / package).is_dir(), f"missing package directory: {package}"


@pytest.mark.parametrize("package", PACKAGES)
def test_package_has_documented_init(package: str) -> None:
    init = REPO_ROOT / package / "__init__.py"
    assert init.is_file(), f"missing {package}/__init__.py"

    docstring = ast.get_docstring(ast.parse(init.read_text()))
    assert docstring, f"{package}/__init__.py has no module docstring"
    assert len(docstring.strip()) > 20, (
        f"{package}/__init__.py docstring is too short to explain anything"
    )


@pytest.mark.parametrize("doc", REQUIRED_DOCS)
def test_required_doc_exists_and_is_not_empty(doc: str) -> None:
    path = REPO_ROOT / "docs" / doc
    assert path.is_file(), f"missing docs/{doc}"
    assert len(path.read_text().strip()) > 100, f"docs/{doc} is a stub"


def test_architecture_diagram_exists() -> None:
    assert (REPO_ROOT / "docs" / "diagrams" / "architecture.mermaid").is_file()


def test_current_milestone_plan_exists() -> None:
    plans = sorted((REPO_ROOT / "docs" / "plans").glob("M*-plan.md"))
    assert plans, "no milestone plan found — every milestone starts with a written plan"
