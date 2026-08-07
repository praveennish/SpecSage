# SpecSage — Architecture Decision Records

**These are yours to write. I will not write them for you.**

This file is different from [DECISION-LOG.md](./DECISION-LOG.md). That file is the *record* —
a complete, mechanical trace of what was decided, when, and what it superseded, written so it
can be fed back to an LLM to reconstruct how the architecture evolved.

This file is the *defence*. Six weeks from now, in an interview, nobody will ask you to recite
a decision log. They will ask "why did you do it that way?" and you will have about forty
seconds to answer in your own words. Writing that answer down now, while the reasoning is
fresh, is the entire point — and it only works if the words are yours.

---

## How to write one

Keep them short. One screen each. Use this shape:

```markdown
## ADR-00N — <decision, stated as a claim>

**Date:** YYYY-MM-DD · **Milestone:** M<n> · **Log ref:** D-0XX

**Context.** What was true that forced a choice? What constraint was actually binding?

**Decision.** What we do now, in one sentence.

**Why.** The reasoning in your words. What did you weigh? What did you give up?

**What I'd say in an interview.** Two or three sentences. The version you'd say out loud.
```

The last section is the one that matters. Write it as speech, not prose.

---

## Priority queue

These are the decisions worth the effort, roughly in order of how often they'll come up.
Cross-references point at the raw material in `DECISION-LOG.md`.

| ADR | Topic | Log ref | Why it earns a slot |
|---|---|---|---|
| ADR-001 | Router: classical classifier over fine-tuning | D-003 | The clearest right-sizing signal in the project. Knowing when *not* to reach for the expensive tool. |
| ADR-002 | Teacher/student cascade design | D-004 | Designing around a known limitation instead of hiding it. |
| ADR-003 | Chunking strategy | *(M2)* | Highest-leverage engineering decision in the pipeline — chunk quality determines everything downstream. |
| ADR-004 | Graph schema | *(M4)* | Node granularity and edge types determine which questions the system can answer at all. |
| ADR-005 | Cost circuit breaker | *(M10)* | The part most people skip and regret. Tested, not trusted. |
| ADR-006 | Three-layer infrastructure lifecycle | D-013, D-017 | A constraint (nightly teardown) forced a better property (no undocumented state). |
| ADR-007 | Lambda for request/response, Fargate for batch | D-019, D-020 | Revising a locked decision under cost pressure — and the honest cost of two compute models. |
| ADR-008 | No NAT Gateway | D-007 | Separating the security property that matters from the pattern people reach for by default. |

Six is enough for M13. Eight is better. Zero is a project you can't defend.

---

## Weekly rhythm

At the end of each week, write **one** ADR while it's fresh. Six weeks from now you will not
remember why you chose what you chose — and that recall is the actual deliverable.

- **Week 1** → ADR-003 (chunking) or ADR-008 (no NAT)
- **Week 2** → ADR-004 (graph schema)
- **Week 3** → ADR-001 (router) and ADR-002 (cascade)
- **Week 4** → ADR-005 (circuit breaker), ADR-006, ADR-007

---

<!-- Write your ADRs below this line. -->
