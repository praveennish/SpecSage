"""Corpus acquisition and licence tracking. Filled at M1.

Downloads openly-licensed source documents to S3 `raw/` and records source URL, licence,
retrieval date, and SHA256 for every entry in `manifest.yaml`. A unit test fails the build
if any entry lacks a resolvable licence — licence compliance is a build gate here, not a
convention. See docs/PROVENANCE.md.
"""
