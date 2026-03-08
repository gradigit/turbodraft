# Prompt Eval Human Adjudication Campaign Plan (2026-03-06)

## Goal
Turn curated real-primary prompt pairs into lock-eligible human-adjudicated evidence for the TurboDraft judge-calibration pipeline.

## Active tranche
- Tranche: `batch3_blindfresh`
- Case count: `9`
- Coverage:
  - preset families: `coding`, `review`, `research`, `brainstorm`, `legacy`, `pivot_kr_en_reason_ko`, `pivot_kr_en_optimize_ko`
  - languages: `en-US`, `ko-KR`
  - splits: `dev`, `tune`, `sealed_test`
- Evidence status: **primary-candidate only** until blind human adjudication is completed and compiled/imported
- Blindness rule:
  - raters see only the workbook,
  - fresh blind case IDs are minted from internal curated rows,
  - internal mapping + seed metadata stay out of the reviewer lane.

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

## Why batch3_blindfresh exists
- replace the already-exposed `batch2_closecall` with a fresh blind tranche
- preserve close-call difficulty while removing internal winner/source leakage from reviewer artifacts
- validate the blind-first workbook flow under lower-bias conditions
- accumulate the first genuinely usable hard human labels before strict Arm J / Arm O reruns

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
