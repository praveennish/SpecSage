"""Hybrid retrieval — vector search plus graph expansion. Filled at M5.

**This package must not import any agent framework.** It is a plain library that LangGraph,
Bedrock Agents, Google ADK, the MCP server, or a test harness can all call directly. The
constraint is enforced by an import-linter contract in `pyproject.toml`, because this kind of
boundary erodes silently and is expensive to restore once it has.

See DECISION-LOG D-002.
"""
