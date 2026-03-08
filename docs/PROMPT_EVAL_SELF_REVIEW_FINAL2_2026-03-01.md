# Prompt Eval Self-Review Final2 (2026-03-01)

## Scope
Post-fix re-check of the previously open items in `docs/PROMPT_EVAL_SELF_REVIEW_FINAL_2026-03-01.md`:
- P0-1
- P1-1
- P1-2
- P1-3
- P1-4

## Verification performed
1. Code-path inspection with line-level references.
2. Targeted tamper reproductions for run-manifest validation:
   - Tampered `dataset_hashes[*]` value to fake 64-hex: validator returned `ok: true` (rc=0).
   - Tampered `config_hashes[*]` value to fake 64-hex: validator returned `ok: true` (rc=0).
   - Tampered `gate_manifest_path` + `judge_prompt_path` to missing files: validator returned `ok: false` (rc=3).

---

## Item-by-item status

### P0-1 — Budget caps runtime enforcement
**Status: Partially resolved (not fully closed)**

**What is fixed**
- Orchestrator now reads `budget_caps` and enforces wall/token/cost hard stops:
  - `bench/prompt_eval/tools/phase_orchestrator.py:560`
  - `bench/prompt_eval/tools/phase_orchestrator.py:836-850`

**Remaining blocker**
- Token/cost ledger is only incremented when `details["codex_eval"]` exists:
  - `bench/prompt_eval/tools/phase_orchestrator.py:827-834`
- Phase B (`calibrate_judge`, `assess_judge_symmetry`, `generate_judge_audit`) does not feed usage totals into cycle accounting:
  - `bench/prompt_eval/tools/phase_orchestrator.py:420-426`

**Impact**
Cycle cost/token caps can still undercount real spend paths (especially judge-reliability work), so caps are not yet comprehensive.

---

### P1-1 — Run-manifest integrity forgeability
**Status: Partially resolved (still open)**

**What is fixed**
- `gate_manifest_path` existence + SHA match now enforced:
  - `bench/prompt_eval/tools/validate_run_manifest.py:75-90`
- `judge_prompt_path` existence + SHA match now enforced:
  - `bench/prompt_eval/tools/validate_run_manifest.py:92-106`

**Remaining blocker**
- `dataset_hashes` and `config_hashes` are validated for shape/keyset only, not recomputed against file content:
  - `bench/prompt_eval/tools/validate_run_manifest.py:129-183`
- Repro confirms tampered dataset/config hashes still pass (`ok: true`, rc=0).

**Impact**
Dataset/config provenance in run manifests is still forgeable.

---

### P1-2 — Pairwise order bias in promotion path
**Status: Mostly resolved, with one remaining gate gap**

**What is fixed**
- Pairwise now runs both forward and reverse orientations per repeat:
  - `bench/prompt_eval/run_codex_prompt_eval.py:534-550`
- Disagreement is neutralized to `Tie`, and orientation disagreement rate is reported:
  - `bench/prompt_eval/run_codex_prompt_eval.py:589-595`
  - `bench/prompt_eval/run_codex_prompt_eval.py:701-705`

**Remaining blocker**
- Promotion gates do not enforce a max orientation-disagreement threshold:
  - `bench/prompt_eval/config/gate_manifest.v1.json:35-41`
  - `bench/prompt_eval/tools/evaluate_gates.py:207-242`

**Impact**
High positional instability can remain non-blocking at promotion time.

---

### P1-3 — Timeout handling in judge/draft runners
**Status: Partially resolved (residual observability/gating gap)**

**What is fixed**
- Per-case exception quarantine paths now prevent hard abort behavior in key loops:
  - `bench/prompt_eval/run_codex_prompt_eval.py:557-587`
  - `bench/prompt_eval/calibrate_judge.py:164-178`
  - `bench/prompt_eval/assess_judge_symmetry.py:145-164`
  - `bench/prompt_eval/tools/generate_judge_audit.py:167-197`

**Remaining blocker**
- No explicit timeout classification/aggregation is surfaced as a promotion gate metric:
  - Gate check set has no timeout-rate check: `bench/prompt_eval/tools/evaluate_gates.py:207-242`

**Impact**
Timeout-heavy runs can degrade silently (as generic errors/ties) without a dedicated fail-closed threshold.

---

### P1-4 — `allow_policy_mutation_mid_cycle=false` enforcement
**Status: Resolved**

**Evidence**
- Policy hash baseline captured at cycle start:
  - `bench/prompt_eval/tools/phase_orchestrator.py:567-576`
- Mid-cycle mutation check enforced when policy mutation is disallowed:
  - `bench/prompt_eval/tools/phase_orchestrator.py:600-603`
- Freeze lockfile emitted:
  - `bench/prompt_eval/tools/phase_orchestrator.py:635-637`

---

## Remaining blockers (current)
1. **Comprehensive budget accounting is incomplete** (P0-1 residual): usage caps do not meter all spending paths.
2. **Manifest hash integrity still incomplete** (P1-1): dataset/config hashes are not recomputed and compared.
3. **Orientation instability is not promotion-gated** (P1-2 residual): metric exists but no fail threshold.
4. **Timeout degradation is not promotion-gated** (P1-3 residual): no timeout-rate check in gate evaluation.

## Final verdict
Not fully closed yet for all previously open P0/P1 items.

Current closure state:
- Fully resolved: **1/5** (P1-4)
- Partially resolved with remaining blockers: **4/5** (P0-1, P1-1, P1-2, P1-3)
