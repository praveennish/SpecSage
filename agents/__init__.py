"""Agent orchestration. Filled at M6.

`interfaces.py` defines the framework-agnostic `AgentTool` protocol; LangGraph is an
implementation detail behind it, not a dependency of the contract. Contains the retrieval
agent, the graph-traversal agent, the synthesis agent, and the right-sized router
(logistic regression over embeddings — deliberately not a fine-tuned model, see
DECISION-LOG D-003).
"""
