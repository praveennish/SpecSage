"""MCP server. Filled at M8.

Exposes `search_docs`, `trace_dependency`, `get_section`, and `ask` over the Model Context
Protocol so any Claude client can query the system directly.

Tool descriptions matter more than people expect — they are the prompt a calling agent reads
when deciding whether to invoke the tool. They get drafted here and reviewed by hand.
"""
