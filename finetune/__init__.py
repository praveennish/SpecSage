"""Distillation and the teacher/student cascade. Filled at M9.

Builds a (context, question) → cited-answer dataset from the teacher, filtered to examples
that pass automatic citation verification, then QLoRA-tunes Qwen2.5-7B-Instruct (Apache 2.0,
which keeps the published artifact licence-clean).

The student learns **format and citation behaviour, never facts** — facts always come from
retrieval at inference time. Training runs on Modal/Kaggle free tiers, not EC2
(DECISION-LOG D-022). The student is expected to underperform the teacher on
out-of-distribution questions; that is the designed-for case, not a failure.
"""
