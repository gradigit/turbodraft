# Prompt Eval Self-Review Final3 (2026-03-01)

## Scope
Final targeted re-check for **remaining P0/P1 blockers** in the prompt-eval stack after latest fixes.

## Verification performed
1. **Code-path audit** for prior P0/P1 issues:
   - `bench/prompt_eval/tools/phase_orchestrator.py`
   - `bench/prompt_eval/tools/validate_run_manifest.py`
   - `bench/prompt_eval/tools/evaluate_gates.py`
   - `bench/prompt_eval/run_codex_prompt_eval.py`
2. **Targeted tamper repros** for run-manifest integrity.
3. **Targeted synthetic gate repro** for orientation/timeout strict gating.
4. **Targeted runtime repro** for holdout redaction path.

---

## P0/P1 status by prior blocker

### P0-1 (budget cap enforcement / accounting completeness)
**Status: Partially resolved**

**What is now fixed**
- Cycle budget caps are read and enforced (`wall`, `tokens`, `cost`) and warning ratio is now operational:
  - `bench/prompt_eval/tools/phase_orchestrator.py:560, 843-876`
- Usage ledger now includes phase-B artifacts (calibration/symmetry/judge-audit), not only split eval summaries:
  - `bench/prompt_eval/tools/phase_orchestrator.py:827-840`

**Remaining blocker (P1-NEW-01)**
- Promptfoo spend is still not metered into budget ledger:
  - Promptfoo artifact path exists: `bench/prompt_eval/tools/phase_orchestrator.py:88-102`
  - Budget accumulation only reads `codex_eval` + phase-B `usage_totals`: `bench/prompt_eval/tools/phase_orchestrator.py:827-840`
  - No parsing of `promptfoo_results.json.results.stats.tokenUsage`.

**Impact**
- Token/cost caps can undercount real spend during promptfoo-heavy phases.

---

### P1-1 (run-manifest hash forgeability)
**Status: Resolved**

**Code evidence**
- Dataset/config hash maps are now recomputed and matched against file content:
  - `bench/prompt_eval/tools/validate_run_manifest.py:163-207`

**Repro evidence (2026-03-01)**
- Control manifest validates (`ok: true`, rc=0).
- Tampered `dataset_hashes[*]` now fails (`rc=3`) with mismatch error.
- Tampered `config_hashes[*]` now fails (`rc=3`) with mismatch error.
- Artifact cycle used: `bench/prompt_eval/reports/selfreview-final3-f359ea90/phase0_bootstrap/`

---

### P1-2 (pairwise order bias not gate-enforced)
**Status: Resolved**

**Code evidence**
- Promotion threshold now includes orientation disagreement bound:
  - `bench/prompt_eval/config/gate_manifest.v1.json:41`
- Gate check enforces and blocks in strict mode:
  - `bench/prompt_eval/tools/evaluate_gates.py:229-231, 253-255, 267-271`

**Repro evidence (2026-03-01)**
- Synthetic strict gate run with `pairwise_orientation_disagreement_rate=0.25` returns:
  - `promotion_pairwise_orientation_stability=false`
  - reason code includes `CHECK_FAILED:promotion_pairwise_orientation_stability`

---

### P1-3 (timeout degradation not gate-enforced)
**Status: Resolved**

**Code evidence**
- Promotion threshold now includes timeout rate bound:
  - `bench/prompt_eval/config/gate_manifest.v1.json:42`
- Gate check enforces timeout rate in strict mode:
  - `bench/prompt_eval/tools/evaluate_gates.py:232-234, 253-255, 267-271`

**Repro evidence (2026-03-01)**
- Synthetic strict gate run with `error_stats.model_timeout_rate=0.2` returns:
  - `promotion_timeout_rate=false`
  - reason code includes `CHECK_FAILED:promotion_timeout_rate`

---

## Newly identified remaining blocker

### P0-NEW-01 — Holdout path hard-crashes due missing import in redaction flow
**Status: Open (P0)**

**Code evidence**
- `hashlib` is used in redaction path without import:
  - use site: `bench/prompt_eval/run_codex_prompt_eval.py:500-501`
  - imports section lacks `import hashlib`: `bench/prompt_eval/run_codex_prompt_eval.py:1-10`
- Holdout path always enables redaction:
  - `bench/prompt_eval/tools/phase_orchestrator.py:483-484`

**Runtime repro (2026-03-01)**
```bash
python3 bench/prompt_eval/run_codex_prompt_eval.py --max-cases 1 --out-dir /tmp/selfreview-final3-redact-check --redact-sensitive --timeout 1
```
Observed failure:
- `NameError: name 'hashlib' is not defined` at `run_codex_prompt_eval.py:500`

**Impact**
- Real holdout evaluation path is fail-stop, which can block phaseF/promotion.

---

## Final P0/P1 blocker list (current)
1. **P0-NEW-01**: holdout redaction crash (`hashlib` missing import in `run_codex_prompt_eval.py`).
2. **P1-NEW-01**: budget ledger does not include promptfoo token/cost usage, so caps can undercount.

## Final verdict
Not fully closed for P0/P1.
- Previously open P1 items (manifest hash integrity, orientation gate, timeout gate): **closed**.
- Remaining blockers: **1 P0 + 1 P1**.
