# Prompt Eval Human Adjudication Campaign Plan (2026-03-06)

## Goal
Turn curated real-primary prompt pairs into lock-eligible human-adjudicated evidence for the TurboDraft judge-calibration pipeline.

## Active tranche
- Tranche: `batch4_guidedcore`
- Case count: `6`
- Coverage:
  - preset families: `coding`, `review`, `brainstorm`, `pivot_kr_en_reason_ko`, `pivot_kr_en_optimize_ko`
  - languages: `en-US`, `ko-KR`
  - splits: `dev`, `tune`, `sealed_test`
- Evidence status: **primary-candidate only** until blind human adjudication is completed and compiled/imported
- Blindness rule:
  - raters see only the workbook,
  - fresh blind case IDs are minted from internal curated rows,
  - internal mapping + seed metadata stay out of the reviewer lane.

## Guided blind-core tranche

`batch4_guidedcore` exists to reduce non-expert rater burden **without** weakening lock integrity:

- still blind-first and lock-grade eligible,
- adds `Why this case matters`, `Quick checklist`, and `Disqualifiers to look for`,
- keeps the same required outputs: `winner + confidence (+ optional note)`,
- remains compatible with the canonical blind workbook parser/compile/import path.

Artifacts:
- candidate subsets:
  - `bench/prompt_eval/fixtures/human_adjudication_candidates.batch4_guidedcore_en.jsonl`
  - `bench/prompt_eval/fixtures/human_adjudication_candidates.batch4_guidedcore_ko.jsonl`
- guidance source:
  - `bench/prompt_eval/fixtures/human_adjudication_guidance.batch4_guidedcore.json`
- workbooks:
  - `bench/prompt_eval/fixtures/human_adjudication_workbook.batch4_guidedcore_en.r1.md`
  - `bench/prompt_eval/fixtures/human_adjudication_workbook.batch4_guidedcore_en.r2.md`
  - `bench/prompt_eval/fixtures/human_adjudication_workbook.batch4_guidedcore_ko.r1.md`
  - `bench/prompt_eval/fixtures/human_adjudication_workbook.batch4_guidedcore_ko.r2.md`

Operational helpers:
- `tools/parse_human_adjudication_workbook.py --validate-only` for pre-submit workbook validation,
- `tools/check_human_adjudication_batch_readiness.py` for per-case/per-rater compile readiness,
- `tools/plan_human_adjudication_deficit_batch.py` for metadata-only next-pack planning against frozen lock floors.

## Reviewer workbook artifacts
- Internal curated source: `bench/prompt_eval/fixtures/human_adjudication_candidates.batch3_curated.jsonl`
- Blind candidate set: `bench/prompt_eval/fixtures/human_adjudication_candidates.batch3_blindfresh.jsonl`
- Internal blind mapping: `bench/prompt_eval/fixtures/human_adjudication_candidates.batch3_blindfresh.mapping.jsonl`
- English workbooks:
  - `bench/prompt_eval/fixtures/human_adjudication_workbook.batch3_blindfresh_en.r1.md`
  - `bench/prompt_eval/fixtures/human_adjudication_workbook.batch3_blindfresh_en.r2.md`
- Korean workbooks:
  - `bench/prompt_eval/fixtures/human_adjudication_workbook.batch3_blindfresh_ko.r1.md`
  - `bench/prompt_eval/fixtures/human_adjudication_workbook.batch3_blindfresh_ko.r2.md`
- Post-blind AI assist: generate only **after** blind submission is locked.

## Review protocol
1. Assign **2 primary raters** to the batch.
2. Each rater completes an independent workbook copy.
3. Allowed decisions: `A`, `B`, `Tie`, `BothBad`.
4. Every row must include:
   - `winner`
   - `confidence`
5. Optional note is recommended for `Tie`, `BothBad`, or genuinely ambiguous calls.
6. `Tie` / `BothBad` / disagreement rows go to tie-break review before canonical import.
7. AI appendix is withheld until the blind workbook is submitted.

## Why batch3_blindfresh still exists
- replace the already-exposed `batch2_closecall` with a fresh blind tranche
- preserve close-call difficulty while removing internal winner/source leakage from reviewer artifacts
- validate the blind-first workbook flow under lower-bias conditions
- accumulate the first genuinely usable hard human labels before strict Arm J / Arm O reruns

Current usage:
- `batch4_guidedcore` = current recommended **easier blind-core** tranche for label collection
- `batch3_blindfresh` = harder follow-on tranche once guided-core throughput is flowing

## Exit criteria for batch3_blindfresh
- `>=2` complete rater workbooks
- no missing required fields
- unresolved rows either tie-broken or explicitly excluded from canonical import
- compiled canonical rows pass import + integrity checks

## Post-review pipeline
1. Compile answers into canonical triplets:
   - `gold`
   - `perturbation`
   - `pairwise`
2. Import compiled rows through the human-adjudicated importer.
3. Run dataset integrity checks.
4. Run **Arm J strict**.
5. Run **Arm O strict + replication**.
6. Rerun judge lock preflight.

## Campaign scaling targets
- `>=500` adjudicated pairwise labels
- `>=200` sealed labels
- `>=5` preset families with 40+ items each across the campaign
- `>=2` languages with 80+ items each across the campaign

## Risks to watch
- reviewer bias from exposed source metadata
- too many obviously weak negatives that overstate judge skill
- insufficient sealed coverage
- unresolved ties reducing usable evidence volume

## Prior tranche disposition
- `batch1`: keep as workflow/smoke evidence only
- `batch2_closecall`: keep as internal design tranche only; not active for blind review because it was already exposed and carried internal metadata leakage

## Operating rule
Batch1 is a **quality-and-flow tranche**, not a sufficient lock tranche by itself. Use it to validate the workflow and accumulate real-primary evidence, then continue scaling until frozen lock floors are met.
