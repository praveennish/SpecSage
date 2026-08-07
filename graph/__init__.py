"""Knowledge graph construction. Filled at M4.

Two-pass cross-reference extraction into Neo4j AuraDB:
  1. Regex over explicit references ("See Section X.Y", "refer to register Z") — high precision.
  2. LLM-assisted pass over chunks with no regex hit, where the model must quote the exact
     source text supporting each edge. The quote is stored on the edge.

No unattributable edges. Ever. An edge you cannot trace to source text is indistinguishable
from a hallucination, and the graph is only useful if you can trust it.
"""
