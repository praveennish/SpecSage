# SpecSage

Agentic RAG + knowledge graph over openly-licensed computer-architecture documentation,
exposed as an MCP server and a public website, with a distilled open-weight model behind a
teacher/student cascade.

> **Status: M0 of 13.** Scaffolding and docs are in place; nothing is deployed yet.
> The real README lands at M13. Until then, start with the docs below.

---

## Docs

| File | What it holds |
|---|---|
| [ARCHITECTURE.md](docs/ARCHITECTURE.md) | Living system design — current state and target shape |
| [DECISION-LOG.md](docs/DECISION-LOG.md) | Every decision, its reasoning, and what it superseded |
| [DECISIONS.md](docs/DECISIONS.md) | Owner-authored ADRs, written for interview defence |
| [RUNBOOK.md](docs/RUNBOOK.md) | Setup, deploy, teardown, troubleshooting |
| [COSTS.md](docs/COSTS.md) | Estimated vs actual, and where the money didn't go |
| [PROVENANCE.md](docs/PROVENANCE.md) | Every source, its licence, and why it was included |
| [plans/](docs/plans/) | Per-milestone plans, written before any code |

---

## Quick start

```bash
make install     # sync the Python 3.12 environment
make test        # unit tests
make run-local   # http://localhost:8000/health
```

AWS setup is [RUNBOOK §1](docs/RUNBOOK.md#1-first-time-aws-setup--owner-tasks).

---

## Shape

```
CloudFront (free TLS) → Lambda (FastAPI) → Qdrant Cloud · Neo4j AuraDB · Bedrock
                                              ▲
              Step Functions → Fargate batch ─┘   (ingest · chunk · embed · graph · eval)
```

Infrastructure is split into three lifecycle layers — `bootstrap` and `data` are never
destroyed; `compute` is torn down between work sessions. Idle cost is about **$1/month**.

---

## License

Code: MIT. Corpus documents retain their original licences — see
[PROVENANCE.md](docs/PROVENANCE.md). Not affiliated with or endorsed by Arm.
