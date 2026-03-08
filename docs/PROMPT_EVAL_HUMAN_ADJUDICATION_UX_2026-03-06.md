# Prompt Eval Human Adjudication UX (2026-03-06)

## Goal
Design a practical human-review workflow that turns candidate prompt pairs into lock-grade evidence for the TurboDraft judge benchmark.

> Note: see `docs/PROMPT_EVAL_HUMAN_ADJUDICATION_REDESIGN_2026-03-06.md` for the updated recommendation to move the main human lane to pairwise-first markdown workbooks (`winner + confidence + optional note`) and treat AI opinions as post-blind assist only.

## Recommendation
Use a **two-file review kit** for the first production tranche:
1. **Markdown packet** for reading context and judging each case.
2. **CSV answer sheet** for structured entry that can later be compiled into canonical import rows.

This is better than markdown-only because:
- markdown is comfortable for reading long prompts,
- CSV is much better for structured capture, aggregation, disagreement handling, and import automation,
- it keeps the UX simple enough to start immediately without building a separate UI app.

## Why not markdown-only?
Markdown-only is acceptable for tiny pilot batches, but it scales badly once you need:
- multiple raters,
- disagreement resolution,
- structured defect tags,
- import-ready aggregation,
- auditability.

So the recommended UX is **markdown + CSV**, with markdown containing checkbox-style guidance and the CSV acting as the actual answer record.

## Reviewer flow
> A packet is only lock-useful after a resolved winner exists and the answers are compiled into the canonical `gold` / `perturbation` / `pairwise` triplet shape.

1. Open the markdown packet.
2. Read the short instructions and defect taxonomy once.
3. For each case:
   - read the draft,
   - compare Candidate A vs Candidate B,
   - pick `A`, `B`, `Tie`, or `BothBad`,
   - assign 0-100 quality scores to both prompts,
   - record defect tags for A/B when a material defect is present (especially low-confidence, `Tie`, or `BothBad` cases),
   - leave notes when uncertain or when using `Tie` / `BothBad`.
4. Record answers in the companion CSV only.
5. Hand the filled CSV back for conversion/import.

## UX rules
- `decision` is mandatory for every case: `A`, `B`, `Tie`, or `BothBad`.
- `rater_id_hashed`, `quality_a_0_100`, and `quality_b_0_100` are mandatory for every answer row.
- defect tags are optional for clear high-confidence wins, but strongly recommended for low-confidence, `Tie`, `BothBad`, or materially flawed prompts.
- `Tie` and `BothBad` cases must go to tie-break review before canonical import.
- Randomize A/B orientation before packet generation.
- Hide source model names from the reviewer when possible.
- Keep reviewer-facing packets and answer sheets **blinded by default**: do not expose source IDs, seed expectations, or model/vendor hints unless running an explicit internal QA pass.
- Keep packets to **20-30 cases** each.
- Use **2 primary raters + 1 tie-breaker**.
- Require short notes when confidence is low (`<=2/5`).
- Do not ask reviewers to author gold prompts from scratch inside the packet; only adjudicate candidate prompts.

## Decision rubric
Reviewers should prefer the prompt that better satisfies prompt-engineering quality, not stylistic preference.

### Core criteria
1. Preserves the user objective correctly.
2. Preserves explicit constraints and uncertainty.
3. Produces a clear, usable execution contract.
4. Avoids scope fabrication and filler.
5. Handles language / safety / structure requirements correctly.
6. Is testable or verifiable when the task needs it.

## Allowed decisions
- `A` — Candidate A is clearly better.
- `B` — Candidate B is clearly better.
- `Tie` — genuinely equivalent in engineering quality.
- `BothBad` — both are materially unacceptable.

## Defect taxonomy
- `missing_constraint`
- `scope_fabrication`
- `structural_noncompliance`
- `unverifiable_output`
- `prompt_injection_leak`
- `ambiguity`
- `verbosity_bloat`
- `language_mismatch`
- `tool_mismatch`
- `other`

## Batch sizing
Recommended lock-aware campaign math:
- packet size: 20-30 pairwise cases
- per packet: balanced English/Korean coverage where possible
- campaign target: at least 500 adjudicated pairwise labels and 200 sealed labels
- family target: at least 5 preset families with 40+ items each across the campaign
- language target: at least 2 languages with 80+ items each across the campaign
- operational target: plan for >500 total pairwise labels so attrition/tie exclusions do not sink lock eligibility

## Output artifacts
The packet builder should emit:
- markdown review packet,
- CSV answer sheet,
- stable text hashes for draft/A/B,
- case IDs and source IDs for later audit.

## Future upgrade path
If review volume becomes high, move from markdown+CSV to a lightweight local HTML review tool. But markdown+CSV is the best near-term trade-off between speed, auditability, and implementation effort.

## Supporting tools
- `bench/prompt_eval/tools/build_human_adjudication_packet.py`
- `bench/prompt_eval/tools/compile_human_adjudication_rows.py`

The builder creates reviewer-facing markdown + CSV. The compiler turns completed answer sheets into canonical import-ready rows.
