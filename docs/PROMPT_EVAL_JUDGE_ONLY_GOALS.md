# Prompt Eval: Judge-Only Goals (Compaction-Safe)

Last updated: 2026-03-06

## Primary objective
Lock an LLM judge that accurately scores **real prompt engineering quality**.

## Non-goals (until lock)
- Do not optimize drafting presets yet.
- Do not treat synthetic perturbation wins as lock evidence.
- Do not promote any judge prompt without sealed-holdout pass.

## Canonical promotion criteria
All lock criteria are frozen in:
- `docs/PROMPT_EVAL_JUDGE_LOCK_SPEC_2026-03-06.md`

No threshold edits are allowed after a strict lock cycle starts.

## Lock status policy
- `NO_LOCK`: any hard gate fails.
- `J_LOCK_ONLY`: Arm J passes, Arm O fails (not production).
- `LOCK`: Arm J + Arm O pass.

## Current status
- Lock state: `NO_LOCK`.
- Active baseline: keep v6 operational.
- v7: experimental only.
- Judge execution target for the next strict cycle: `gpt-5.4` with `xhigh` reasoning effort.
- Historical `gpt-5.3-codex` lock artifacts remain archival and non-comparable to future `gpt-5.4` runs unless rerun on the new baseline.
- Primary blocker: pairwise labels below floor (`225 < 500`).

## Next sequence
1. Freeze and enforce lock spec.
2. Curate/import real engineered benchmark rows using the high-quality source registry plus prior TurboDraft research as seed/reference material only.
3. Recalibrate judge (Arm J) and run strict sealed cycle on the `gpt-5.4 xhigh` baseline.
4. Run Arm O external-validity cycle.
5. Decide `NO_LOCK` / `J_LOCK_ONLY` / `LOCK`.

