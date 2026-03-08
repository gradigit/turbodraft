# TurboDraft Prompt Evaluation (Pilot Harness)

This folder contains a concrete pilot pipeline to evaluate drafting prompts with Codex as:
1) **drafting model** (generates rewritten prompts), and
2) **LLM judge** (pairwise evaluator).

It now also includes an autonomous phase runner and Promptfoo split configs for CI wiring.
For local/offline runs, `--simulate-no-provider` enables simulated artifacts for:
- Promptfoo provider runs,
- Judge reliability in phase B,
- Split eval summaries in phases D/E/F.
Simulated artifacts are **explicitly non-promotable** in phase G.

## Goals

- Compare prompt variants objectively before changing production presets.
- Gate on both deterministic contract checks and model-graded pairwise outcomes.
- Calibrate judge prompt quality before trusting judge decisions.

## Structure

- `datasets/pilot_cases.jsonl` — representative cross-preset pilot cases.
- `datasets/judge_calibration_pairs.jsonl` — labeled pairwise set for judge prompt calibration.
- `variants/` — prompt-variant overlays applied to current instructions (including `overlay_hygiene_guard.md`).
- `prompts/judge_pairwise_v1.md` ... `judge_pairwise_v7.md` — competing judge prompts.
- `prompts/drafter_*.md` — benchmark drafting prompt variants for Promptfoo runs (including `drafter_hygiene_guard.md`).
- `providers/promptfoo_cli_provider.py` — Promptfoo custom Python provider routing to `codex exec`/`claude -p`.
- `schemas/judge_decision.schema.json` — strict JSON output contract for judge decisions.
- `calibrate_judge.py` — picks best judge prompt on labeled pairs.
- `run_codex_prompt_eval.py` — runs generation + deterministic checks + pairwise judging.
- `tools/phase_orchestrator.py` — executes autonomous phases with manifests and self-review.
- `tools/validate_gate_manifest.py` — fail-closed gate manifest validation.
- `tools/validate_holistic_sources.py` — validates provider coverage for holistic research sources (OpenAI/Anthropic/Google/Promptfoo + recent papers).
- `tools/check_dataset_integrity.py` — split leakage/duplication checks.
- `tools/build_judge_quality_dataset.py` — builds deterministic M1 judge-quality datasets (`gold_prompts`, `perturbations`, `pairwise_labels`, split manifest).
- `tools/export_judge_quality_legacy_calibration.py` — exports judge-quality data into legacy calibration file shapes.
- `tools/run_judge_quality_calibration.py` — Arm J calibration runner on judge-quality labels (agreement, critical recall, calibration reliability gates).
- `tools/run_judge_invariance_suite.py` — Arm J invariance + prompt-injection robustness suite (order swap, repeats, paraphrase/verbosity drift, bias, ASR).
- `tools/run_outcome_lite_eval.py` — Arm O lite aggregation with a single sequential Holm inferential regime and exploration quota/tail audit fields.
- `tools/run_judge_outcome_meta_agreement.py` — computes judge↔outcome rank agreement (Spearman + bootstrap CI) for lock checks.
- `tools/assess_judge_lock_readiness.py` — frozen lock-spec readiness verdict (`NO_LOCK` / `J_LOCK_ONLY` / `LOCK`) with explicit reason codes.
- `tools/build_human_adjudication_packet.py` — renders markdown review packets + CSV answer sheets from candidate prompt pairs.
- `tools/compile_human_adjudication_rows.py` — compiles completed answer sheets into canonical `gold` / `perturbation` / `pairwise` JSONL rows for import.
- `tools/build_human_adjudication_workbook.py` — renders blinded markdown workbooks for direct human editing (`winner + confidence + optional note`).
- `tools/parse_human_adjudication_workbook.py` — parses filled workbooks into legacy-compatible answer rows using a confidence-to-score compatibility mapping.
- `tools/build_human_adjudication_assisted_workbook.py` — renders an AI-assisted expansion-lane workbook from a blind workbook + AI assist JSONL.
- `tools/parse_human_adjudication_assisted_workbook.py` — parses AI-assisted expansion workbooks into compatibility answer rows while preserving assist metadata.
- `tools/materialize_blind_adjudication_candidates.py` — strips internal winner/source metadata, mints fresh blind case IDs, and writes a separate internal mapping file.
- `tools/build_human_adjudication_tiebreak_workbook.py` — builds a third-rater blind workbook from disagreement / Tie / BothBad / low-confidence parsed answer rows.
- `tools/generate_human_adjudication_ai_assist.py` — generates a provider-backed AI-assist appendix for post-blind adjudication review (currently Auggie GPT-5.4 via `judge_secondary`).
- `datasets/judge_quality/` — internal reboot dataset family (dev/tune/sealed_test with split manifest governance + provenance metadata).
- `fixtures/reference_prompt_seed_bank.v1.jsonl` — concrete seed bank of official/local prompt artifacts to adapt into human-adjudicated benchmark candidates.
- `fixtures/human_adjudication_candidates.batch1.jsonl` — first real-primary candidate tranche for human review.
- `fixtures/human_adjudication_packet.batch1.md` / `fixtures/human_adjudication_answers.batch1.csv` — blinded reviewer kit generated from `batch1`.
- `fixtures/human_adjudication_candidates.batch3_blindfresh*.jsonl` — active fresh blind candidate tranche derived from internal curated close-call rows.
- `fixtures/human_adjudication_workbook.batch3_blindfresh_{en,ko}.{r1,r2}.md` — active blind-first workbooks for the next human pass.
- `reports/` — timestamped outputs.
- `config/*.promptfoo.yaml` — Promptfoo split configs (dev/adversarial/holdout), CLI-backed (no OpenAI API key required).
- `config/providers.v1.json` — single source of truth provider/model/reasoning contract.
  - includes required `judge_primary` + `judge_shadow` and optional `judge_secondary` (Gemini escalation lane).

## Quickstart

From repo root:

```bash
python3 bench/prompt_eval/calibrate_judge.py \
  --model gpt-5.4 \
  --reasoning-effort xhigh

python3 bench/prompt_eval/run_codex_prompt_eval.py \
  --provider-contract bench/prompt_eval/config/providers.v1.json \
  --judge-prompt bench/prompt_eval/prompts/judge_pairwise_v2.md \
  --judge-schema bench/prompt_eval/schemas/judge_decision.schema.json
```

Optional flags:

```bash
python3 bench/prompt_eval/run_codex_prompt_eval.py \
  --max-cases 4 \
  --judge-prompt bench/prompt_eval/prompts/judge_pairwise_v3.md \
  --pairwise-repeats 5
```

Evaluate the experimental hygiene overlay explicitly (kept out of default variant set to control baseline token cost):

```bash
python3 bench/prompt_eval/run_codex_prompt_eval.py \
  --variants \
    bench/prompt_eval/variants/overlay_baseline.md \
    bench/prompt_eval/variants/overlay_contract_selfcheck.md \
    bench/prompt_eval/variants/overlay_precision_guard.md \
    bench/prompt_eval/variants/overlay_hygiene_guard.md
```

High-quality escalation mode (Codex primary + Gemini/Opus escalation for uncertain cases):

```bash
python3 bench/prompt_eval/run_codex_prompt_eval.py \
  --provider-contract bench/prompt_eval/config/providers.v1.json \
  --enable-judge-escalation \
  --escalation-on-critical \
  --escalation-score-margin-points 1.0 \
  --escalation-confidence-threshold 0.65 \
  --escalation-score-margin-max 0.05 \
  --pairwise-mirror-mode critical \
  --pairwise-critical-repeats 5 \
  --pairwise-noncritical-repeats 1
```

Promptfoo split evals now run through local CLI providers. As long as your local CLIs are authenticated
(`codex`, and optionally `claude` for shadow paths), Promptfoo does not require `OPENAI_API_KEY`.
When Promptfoo returns `rc=100` for assertion-only failures, orchestrator records this as
`raw_returncode=100` and continues (evaluation signal), while still failing closed for runtime/provider errors.

Note: promotion gate in phase G runs in **strict mode by default** and now requires:
- a real-provider judge-audit artifact,
- provider lock compliance (`gpt-5.4 xhigh` primary, `claude-opus-4-6 high` shadow).
- Arm J + Arm O artifacts (`--armj-calibration-summary-path`, `--armj-invariance-summary-path`, `--armo-summary-path`).

For fully simulated local smoke runs, you can still run all phases, but phase G remains non-promotable.
For strict real-provider promotions, provide a judge-audit artifact via
`--judge-audit-path` (or place `judge_audit.json` under the phase B report folder for the same cycle).

Direct `evaluate_gates.py` invocation is also strict by default.
Use `--non-strict` only for exploratory/local diagnostics.

## Human adjudication workflow

The current real-primary workflow is:

1. curate candidate prompt pairs into an **internal** JSONL,
2. materialize a **fresh blind** candidate JSONL with `tools/materialize_blind_adjudication_candidates.py`,
3. render a **blinded** markdown workbook with `tools/build_human_adjudication_workbook.py`,
4. collect at least 2 independent blind human workbooks,
5. parse those workbooks into compatibility answer rows with `tools/parse_human_adjudication_workbook.py`,
6. compile those rows into canonical `gold` / `perturbation` / `pairwise` rows with `tools/compile_human_adjudication_rows.py`,
7. import via the human-adjudicated importer,
8. only after blind submission, optionally generate a **post-blind** AI appendix with `tools/generate_human_adjudication_ai_assist.py`,
9. run integrity checks, then Arm J / Arm O strict.

Reviewer-facing artifacts should stay blinded by default:
- no source IDs,
- no seed expectations,
- no vendor/model hints.
- no visible case IDs, preset families, or split labels during the blind pass.

AI assist should **not** be shown before the blind human decision.
Lock-grade truth remains the blind-first human label; post-assist revisions are secondary workflow metadata only.

### Hybrid adjudication lanes

Use two lanes rather than forcing one workflow to do everything:

- **Lane A — blind gold lane**
  - independent human labels,
  - lock-grade,
  - use `tools/build_human_adjudication_workbook.py` and `tools/parse_human_adjudication_workbook.py`.
- **Lane B — AI-assisted expansion lane**
  - higher-throughput, non-lock,
  - human sees the current `judge_secondary` model assessment first and records agree/override + final winner,
  - use `tools/generate_human_adjudication_ai_assist.py`,
    `tools/build_human_adjudication_assisted_workbook.py`,
    and `tools/parse_human_adjudication_assisted_workbook.py`.

Compiled rows now preserve `review_metadata.adjudication_lane` and `review_metadata.lock_eligible`
so downstream analysis can distinguish blind gold evidence from assisted-expansion evidence.

`batch1` is a workflow-validation + evidence-accumulation tranche, **not** a lock-sufficient tranche by itself.
`batch2_closecall` is now treated as an internal/exposed design tranche, **not** the active blind batch.

## Judge-quality dataset workflow (M1)

Build deterministic judge-quality artifacts:

```bash
export PROMPT_EVAL_JUDGE_QUALITY_MANIFEST_SECRET="<strong-secret>"
python3 bench/prompt_eval/tools/build_judge_quality_dataset.py
```

`--real-primary-profile` now only disables synthetic negatives; it does **not** convert this generator into
human-adjudicated evidence. By default, provenance labels implying human/real adjudication are blocked for this
synthetic builder (override only with `--allow-unverified-provenance-claims` for local experiments).

Import real human-adjudicated artifacts into canonical judge-quality layout:

```bash
export PROMPT_EVAL_JUDGE_QUALITY_MANIFEST_SECRET="<strong-secret>"
python3 bench/prompt_eval/tools/import_human_judge_quality_dataset.py \
  --source bench/prompt_eval/fixtures/judge_quality_human_rows.template.jsonl \
  --out-dir bench/prompt_eval/datasets_human/judge_quality
```

Importer notes:
- accepts `.jsonl`, `.json`, or `.csv` sources (repeat `--source` to merge multiple files),
- enforces `label_source_class=human_adjudicated`,
- canonicalizes hashes / pairwise linkage fields,
- signs detached manifest using the same fail-closed signature contract as the synthetic builder,
- writes `split_validation_mode=exact_per_family` so integrity checks validate imported split counts exactly rather than assuming builder-style 60/20/20 ratios.

Reference-source policy notes:
- concrete seed bank artifact: `bench/prompt_eval/fixtures/reference_prompt_seed_bank.v1.jsonl`,
- candidate-pair template: `bench/prompt_eval/fixtures/human_adjudication_candidates.template.jsonl`,
- sample candidate batch: `bench/prompt_eval/fixtures/human_adjudication_candidates.sample.jsonl`,
- external prompt guides / CLI scaffold prompts are **seed sources only** until adapted to TurboDraft use cases and imported through the canonical human-adjudicated path,
- prior TurboDraft research artifacts are valid reference context for rubric/source selection but are **not** gold labels by themselves,
- active source registry: `bench/prompt_eval/config/high_quality_prompt_sources.v1.json`,
- active synthesis: `architect/research/high-quality-prompt-sources-2026-03-06.md`.

Recommended source fields for real-primary imports:
- common: `id`, `preset_family`, `item_type`, `language_tag`, `split`, `adjudication_status`,
  `provenance_source`, `provenance_artifact`,
- gold / perturbation: `prompt_text`, `absolute_score_0_100`, `blinded_ratings`,
- perturbation / pairwise: `parent_prompt_id`,
- pairwise: `candidate_a`, `candidate_b`, `perturbation_id` (recommended; required for strict linkage).

Required integrity env vars:
- `PROMPT_EVAL_JUDGE_QUALITY_MANIFEST_SECRET`: required by default; builder fails closed without it (unless explicit local-dev override is used).
- `PROMPT_EVAL_JUDGE_QUALITY_BREAK_GLASS_TOKEN_HASH`: optional trusted SHA-256 hash used to validate repeated sealed exports.

Run integrity checks (legacy splits + judge-quality controls):

```bash
python3 bench/prompt_eval/tools/check_dataset_integrity.py
```

Local-dev compatibility override (explicit opt-out only):

```bash
python3 bench/prompt_eval/tools/build_judge_quality_dataset.py \
  --allow-unsigned-manifest-signature

python3 bench/prompt_eval/tools/check_dataset_integrity.py \
  --allow-unsigned-manifest-signature
```

Integrity checks now enforce:
- observed `preset_family` set equals `split_manifest.v1.json` family set,
- detached manifest signature validation (fail-closed when required),
- imported datasets may opt into `split_validation_mode=exact_per_family` to validate manifest-declared gold counts exactly,
- judge_quality near-duplicate checks across `dev`/`tune`/`sealed_test`.

Export to legacy calibration file shapes (default includes `dev+tune`, excludes `sealed_test`):

```bash
export PROMPT_EVAL_JUDGE_QUALITY_MANIFEST_SECRET="<strong-secret>"
python3 bench/prompt_eval/tools/export_judge_quality_legacy_calibration.py
```

Exporter includes only adjudicated `gold` + adjudicated `perturbation` rows.

One-time sealed export requires explicit reason:

```bash
python3 bench/prompt_eval/tools/export_judge_quality_legacy_calibration.py \
  --open-sealed-test \
  --open-sealed-test-reason "judge lock decision run"
```

If `sealed_open_count > 0`, repeated sealed export is fail-closed unless break-glass token is supplied:

```bash
python3 bench/prompt_eval/tools/export_judge_quality_legacy_calibration.py \
  --open-sealed-test \
  --open-sealed-test-reason "emergency re-run approved by evaluator owner" \
  --break-glass-token "<token>"
```

Repeated sealed export also requires a trusted token hash (via `PROMPT_EVAL_JUDGE_QUALITY_BREAK_GLASS_TOKEN_HASH`
or `governance.trusted_break_glass_token_hash` in the manifest); provided token is validated with constant-time hash comparison.
Exporter also verifies detached manifest signature before reading governance state.

## Arm J runners (M2)

Calibration (default `dev,tune`, strict lock-style thresholds):

```bash
python3 bench/prompt_eval/tools/run_judge_quality_calibration.py \
  --provider-contract bench/prompt_eval/config/providers.v1.json \
  --judge-prompt bench/prompt_eval/prompts/judge_pairwise_v6.md
```

Simulation mode (CI-safe):

```bash
python3 bench/prompt_eval/tools/run_judge_quality_calibration.py \
  --simulate-no-provider \
  --min-pairwise-labels 50
```

Invariance + injection suite:

```bash
python3 bench/prompt_eval/tools/run_judge_invariance_suite.py \
  --provider-contract bench/prompt_eval/config/providers.v1.json \
  --judge-prompt bench/prompt_eval/prompts/judge_pairwise_v6.md
```

## Arm O lite + meta-agreement (M3)

Aggregate split summaries into Arm O lite outcome report:

```bash
python3 bench/prompt_eval/tools/run_outcome_lite_eval.py \
  --phase-summaries bench/prompt_eval/fixtures/split_eval_summary.simulated.json \
  --simulate-no-provider
```

Judge↔Outcome rank agreement:

```bash
python3 bench/prompt_eval/tools/run_judge_outcome_meta_agreement.py \
  --judge-summary bench/prompt_eval/fixtures/split_eval_summary.simulated.json \
  --outcome-summary bench/prompt_eval/reports/<armo_run>/summary.json
```

Frozen lock-spec readiness preflight:

```bash
python3 bench/prompt_eval/tools/assess_judge_lock_readiness.py \
  --out bench/prompt_eval/reports/lock_readiness_latest.json
```

Preflight now fails closed on:
- dataset integrity/signature verification via `check_dataset_integrity.py`,
- required family membership from `gate_manifest.v1.json`,
- sealed split label-source-class policy (default: `human_adjudicated`),
- missing/invalid Arm J/Arm O artifact structure (summary + by_case evidence),
- Arm J/Arm O-linked dataset fingerprint mismatch vs active dataset.

Use `--fail-on-no-lock` when non-LOCK should fail CI.

## Output artifacts

### Judge calibration

`reports/judge_calibration_*/summary.json`

Key fields:
- `accuracy`
- `invalid_count`
- `recall_A`, `recall_B`, `recall_Tie`
- `recommended_prompt`
- `confidence_calibration` (bin-level expected-vs-observed diagnostics)

### Prompt eval

`reports/pilot_*/summary.json`

Key fields:
- deterministic hard-pass rate by variant
- deterministic average score by variant
- pairwise win/loss/tie vs baseline
- family-level pairwise winners
- promotion statistics (Holm-adjusted p-values, repeat stddev, critical-failure counters)

## How to expand to production

1. Increase dataset size (50+ per preset family).
2. Expand and rotate hidden holdout partitions (lockbox style).
3. Add human adjudication sample and judge-human agreement gates.
4. Run nightly in CI and block on regression thresholds.
5. Promote winning variants into `bench/presets/instructions/` only after holdout pass.

## Autonomous phase execution

```bash
python3 bench/prompt_eval/tools/phase_orchestrator.py --phase phase0_bootstrap --cycle-id local-cycle
python3 bench/prompt_eval/tools/phase_orchestrator.py --phase phaseA_policy_freeze --cycle-id local-cycle
python3 bench/prompt_eval/tools/phase_orchestrator.py --phase phaseB_judge_reliability --cycle-id local-cycle --max-cases 6
python3 bench/prompt_eval/tools/phase_orchestrator.py --phase phaseC_candidate_generation --cycle-id local-cycle
python3 bench/prompt_eval/tools/phase_orchestrator.py --phase phaseD_dev --cycle-id local-cycle --max-cases 3 --simulate-no-provider
python3 bench/prompt_eval/tools/phase_orchestrator.py --phase phaseE_adversarial --cycle-id local-cycle --max-cases 3 --simulate-no-provider
PROMPT_EVAL_ALLOW_HOLDOUT=1 python3 bench/prompt_eval/tools/phase_orchestrator.py --phase phaseF_holdout --cycle-id local-cycle --max-cases 3 --simulate-no-provider
python3 bench/prompt_eval/tools/phase_orchestrator.py --phase phaseG_promotion --cycle-id local-cycle --non-strict-promotion
```

If you need to bypass Promptfoo temporarily (while still running Codex/Claude split evals), add:

```bash
python3 bench/prompt_eval/tools/phase_orchestrator.py --phase phaseD_dev --cycle-id local-cycle --skip-promptfoo
```

## Holistic source policy gate

The gate manifest includes a `source_policy` block requiring:
- cross-provider source coverage (OpenAI, Anthropic, Google, Promptfoo),
- a minimum total source count, and
- a minimum number of recent non-provider research papers.

Manual check:

```bash
python3 bench/prompt_eval/tools/validate_holistic_sources.py
```

## Human adjudication packet workflow

Build a reviewer packet + answer sheet:

```bash
python3 bench/prompt_eval/tools/build_human_adjudication_packet.py \
  --candidates bench/prompt_eval/fixtures/human_adjudication_candidates.sample.jsonl \
  --packet-out bench/prompt_eval/fixtures/human_adjudication_packet.sample.md \
  --answers-out bench/prompt_eval/fixtures/human_adjudication_answers.sample.csv
```

After the answer sheet is filled, compile it into canonical import rows:

```bash
python3 bench/prompt_eval/tools/compile_human_adjudication_rows.py \
  --candidates bench/prompt_eval/fixtures/human_adjudication_candidates.sample.jsonl \
  --answers bench/prompt_eval/fixtures/human_adjudication_answers.sample.csv \
  --out bench/prompt_eval/fixtures/human_adjudication_rows.compiled.jsonl \
  --provenance-source human_panel_batch_01 \
  --provenance-artifact round_01 \
  --min-raters 2 \
  --skip-unresolved
```
