"""Chunk embedding and vector upsert. Filled at M3.

Reads `processed/chunks.jsonl` from S3, embeds via Bedrock Titan
(`amazon.titan-embed-text-v2:0`), and upserts to Qdrant Cloud with the full metadata payload.
Batched, with retry and backoff on throttling.
"""
