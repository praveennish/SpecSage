"""Evaluation harness. Filled at M7.

The highest-value artifact in the project. Contains the golden-set review CLI
(`python -m eval.review`) and the scoring harness that runs every golden question through the
**live** `/answer` endpoint — testing what is deployed, not a local pipeline.

LLM-generated answers are candidates, never ground truth. `golden_qa.jsonl` is hand-verified
and lives in git, because it is the one artifact here that cannot be regenerated.
"""
