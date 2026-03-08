# TurboDraft Prompt Evaluation + Prompt Architecture Review
Date: 2026-02-27
Owner: Prompt Evaluation Engineering
Status: Stage 1 complete (design audited + architecture specified)

## 1) Request this document answers

You asked for:
1. A full evaluation of the current eval design.
2. A concrete architecture for prompt construction + preset selection.
3. A first round of candidate prompt-engineering prompts.
4. A determination of whether eval numbers are trustworthy enough to drive prompt promotion/regression decisions.

---

## 2) Full evaluation of current eval design

## 2.1 What was executed

- Judge calibration run (`gpt-5.3-codex`, reasoning `xhigh`) on labeled A/B dataset.
- Judge symmetry/orientation checks (A/B swap invariance).
- Pilot prompt eval run (`gpt-5.3-codex-spark` drafter, `gpt-5.3-codex` judge; both `xhigh`).
- Automated eval-design audit script aggregating all reports.

## 2.2 Evidence snapshot

### Core strengths (validated)

1. **Strict output contract works**
   - Judge JSON is schema-constrained (`additionalProperties: false`).
   - No invalid judge outputs in latest calibration.

2. **Judge behaves consistently on labeled set**
   - Calibration accuracy: 1.00 on 10/10 labeled pairs.
   - Symmetry rate (forward/reverse candidate order): 1.00.
   - Repeat agreement (subset run with repeats): 1.00.

3. **Harness can detect variant differences**
   - Pairwise results produce non-trivial wins/losses between variants.
   - Baseline currently outperforms candidate overlays in pilot.

### Critical limitations (blocking for truth-level claims)

1. **Sample size is too small**
   - Calibration n=10, pilot n=4 cases.
   - This is enough for directional signal, not enough for production truth claims.

2. **Preset coverage is incomplete in pilot**
   - Pilot includes only: coding, research, brainstorm, pivot_kr_en_optimize_ko.
   - Missing: legacy, refactor, review, pivot_kr_en_translate, pivot_kr_en_reason_ko.

3. **Adversarial/holdout gates are not yet populated at production scale**
   - Current artifacts are pilot-grade.

## 2.3 Quantitative design verdict

From automated audit:
- Check pass rate: **9/10 (90%)**
- Verdict: **READY_FOR_DIRECTIONAL_DECISIONS**
- Not yet: **READY_FOR_TRUTH_LEVEL_GATING**

Blocking reasons:
- Calibration sample size below 30.
- Pilot dataset too small for production truth claims.

### Practical interpretation

- You can use current numbers to prioritize which variants to test next.
- You should **not** treat current numbers as final truth for shipping decisions.

---

## 3) Prompt engineering architecture (exact, stage-1 decision)

## 3.1 Design decision

Adopt **Preset-first UX + composable backend pipeline**.

- UI: user selects preset directly (simple mental model).
- Backend: still composes layered prompt artifacts for control and maintainability.
- Profile remains advanced/internal, not primary UX surface.

This addresses your concern that profile+preset is confusing while preserving engineering flexibility.

## 3.2 Construction pipeline (exact)

For each draft request:

1. Resolve preset (explicit user preset first, then fallback policy).
2. Load preamble profile (`large_opt` default).
3. Load preset instruction (`bench/presets/instructions/<preset>.md`).
4. Load preset contract if present (`bench/presets/contracts/<preset>.md`).
5. Optionally add candidate overlay (for benchmarking variants only).
6. Append user draft prompt in delimited source block.
7. Run output guard; if invalid, run repair instruction and retry.

## 3.3 Selection policy (exact)

Priority order:
1. Explicit user-selected preset.
2. Persisted user default preset.
3. Intent-classifier guess.
4. Safe fallback preset (`coding`).

Rule:
- If user explicitly selects preset, do **not** silently reclassify.

## 3.4 Files that define architecture

- `bench/prompt_architecture/v1/preset_registry.json`
- `bench/prompt_architecture/v1/selection_policy.json`
- `bench/prompt_architecture/v1/candidate_prompt_set_round1.json`

---

## 4) First-round candidate prompt-engineering prompts

Round-1 candidate set is defined as benchmark overlays:

1. `baseline`
2. `contract_selfcheck`
3. `precision_guard`

Current pilot result:
- Baseline is strongest overall.
- Both candidate overlays underperform baseline on pairwise wins.

Conclusion:
- Round-1 candidates are useful as negative controls and design probes.
- We should synthesize Round-2 candidates targeted at the observed failure modes (over-constraint and scope drift penalties).

---

## 5) Can we trust these numbers yet?

Short answer: **partially**.

- Trust for directional ranking in a narrow pilot scope: **Yes**.
- Trust for final promotion/regression truth claims: **No (not yet)**.

## Required to reach truth-level trust

1. Calibration set >= 30 labeled pairs (balanced A/B/Tie and mixed presets).
2. Holdout set >= 60 production-like cases.
3. Full preset coverage in dev/adversarial/holdout splits.
4. Stable repeatability across >=3 repeated benchmark runs.
5. Pre-registered gates and paired-CI reporting on holdout.

---

## 6) Immediate next stage (after your approval)

1. Build expanded stratified datasets (dev/adversarial/calibration/holdout).
2. Generate Round-2 candidate overlays/prompt variants based on Round-1 failure reasons.
3. Re-run calibration + symmetry + pilot at scale.
4. Produce go/no-go report for first promotion candidate.

