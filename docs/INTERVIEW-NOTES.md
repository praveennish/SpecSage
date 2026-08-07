# SpecSage — Interview Notes

**Yours to write.** Harvested from [DECISIONS.md](./DECISIONS.md) at M13, one per week before
that. I will prompt you; I will not write them.

**Status:** empty. First entry due end of week 1.

---

## Why this file exists

`DECISION-LOG.md` records what happened. `DECISIONS.md` records why, in your words. This file
records **how you'd say it out loud, under time pressure, to someone who hasn't seen the code.**

Those are three different artifacts and the third is the one that gets you the offer.

---

## Format — STAR, but compressed

Forty seconds of speech. Roughly:

```markdown
## <Decision, as a headline>

**Situation.** One sentence of context. What was the constraint?
**Task.** What did you have to decide?
**Action.** What you did, and the option you rejected.
**Result.** What it cost or saved, and what you'd do differently.

**The 40-second version:** <written as speech, not prose>
**If they push back:** <the strongest counter-argument, and your honest answer>
```

The "if they push back" line is what separates a talking point from a defensible decision.
Every real decision has a cost. Name it before they do.

---

## Priority order

1. **Router: classical classifier, not fine-tuning** — the clearest right-sizing signal
2. **Teacher/student cascade** — designing around a known limitation instead of hiding it
3. **Chunking strategy** — the highest-leverage engineering decision in the pipeline
4. **Graph schema** — node granularity determines which questions are answerable at all
5. **Cost circuit breaker** — the part most people skip; you tested yours
6. **Three-layer infra lifecycle** — a constraint that forced a better property

---

## Questions to have answers ready for

- "Walk me through what happens when a question hits `/answer`."
- "How do you know it's any good?" → M7. Point at the live numbers.
- "What's the worst thing about this design?"
- "Why did you fine-tune at all, if the router doesn't need it?"
- "What would you change if this had to serve 1,000 QPS?"
- "How much did it cost to run, and how do you know?"

---

<!-- Write your notes below this line. -->
