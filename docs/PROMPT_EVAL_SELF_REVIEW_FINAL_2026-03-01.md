# Prompt Eval Self-Review Final (2026-03-01)

## Scope
Re-checked prompt-eval hardening paths after latest fixes:

- `bench/prompt_eval/tools/build_run_manifest.py`
- `bench/prompt_eval/tools/validate_run_manifest.py`
- `bench/prompt_eval/run_codex_prompt_eval.py`
- `bench/prompt_eval/tools/phase_orchestrator.py`
- `bench/prompt_eval/tools/generate_judge_audit.py`
- `bench/prompt_eval/calibrate_judge.py`
- `bench/prompt_eval/assess_judge_symmetry.py`
- `bench/prompt_eval/tools/evaluate_gates.py`
- `bench/prompt_eval/config/gate_manifest.v1.json`

## Verification performed
1. Regression suite:
   - `python3 -m unittest bench.prompt_eval.tests.test_tools -v`
   - Result: **16/16 tests passed**.
2. Manifest tamper repro (manual):
   - Built valid manifest, replaced dataset hash with `000...000`.
   - `validate_run_manifest.py` still returned `ok: true` (rc=0).
3. Manifest tamper repro (manual):
   - Replaced `gate_manifest_path` and `judge_prompt_path` with missing absolute paths.
   - `validate_run_manifest.py` still returned `ok: true` (rc=0).

## Confirmed fixed from prior review
- Missing dataset/config path fail-open in builder fixed (`build_run_manifest.py`).
- `--schema` missing path now correctly fails (`validate_run_manifest.py`).
- Draft/judge primary `runner` mismatch now fail-closed to codex (`run_codex_prompt_eval.py`, `phase_orchestrator.py`).
- Judge transitivity floor now enforced per family (`generate_judge_audit.py`).
- Orchestrator subprocess timeout guards added (`phase_orchestrator.py`).

---

## Remaining P0/P1 findings

### P0-1 — Budget caps are declared but still not runtime-enforced
**Evidence**
- Policy declares hard budget caps: `bench/prompt_eval/config/gate_manifest.v1.json:52-57`.
- Orchestrator reads sample floors but does not read/enforce `budget_caps`: `bench/prompt_eval/tools/phase_orchestrator.py:524-532`.

**Impact**
Runaway token/cost/wall-clock spend is still possible in real-provider cycles despite policy claiming hard caps.

**Required fix**
Add cycle-level budget ledger + hard-stop checks using `budget_caps` (`tokens`, `cost_usd`, `wall_clock_minutes`) with explicit reason codes.

---

### P1-1 — Run-manifest integrity is still forgeable (hash/path trust gap)
**Evidence**
- Validator only checks hash *format* and path-shape/existence for dataset/config entries, not cryptographic match of recorded hashes to file contents: `bench/prompt_eval/tools/validate_run_manifest.py:67-147`.
- `gate_manifest_path` only checked for absolute path, not existence/hash match: `bench/prompt_eval/tools/validate_run_manifest.py:63-69`.
- `judge_prompt_path` checked only as non-empty string: `bench/prompt_eval/tools/validate_run_manifest.py:71`.
- Repro confirmed tampered manifest still validates (`ok: true`) after changing:
  - `dataset_hashes[*]` to fake 64-hex value,
  - `gate_manifest_path`/`judge_prompt_path` to missing files.

**Impact**
Manifest can present false provenance while still passing validation.

**Required fix**
Recompute and compare all declared hashes (gate manifest, datasets, configs, and judge prompt), and require referenced paths to exist.

---

### P1-2 — Pairwise promotion path remains order-biased (A/B orientation fixed)
**Evidence**
- Promotion pairwise always sends challenger as `candidate_a` and baseline as `candidate_b`: `bench/prompt_eval/run_codex_prompt_eval.py:498-505`.
- No mirrored B/A adjudication in phase D/E/F promotion path.

**Impact**
If judge has residual positional bias, win rates can be systematically skewed toward/against challengers.

**Required fix**
For each pairwise comparison, run both orientations (A/B and B/A), map reverse winner back to original frame, and gate on orientation delta.

---

### P1-3 — Timeout exceptions in core judge/draft runners are still unhandled
**Evidence**
- Direct subprocess calls with `timeout=` but no `TimeoutExpired` handling in core runners:
  - `bench/prompt_eval/run_codex_prompt_eval.py:55-61`
  - `bench/prompt_eval/calibrate_judge.py:47-53`
  - `bench/prompt_eval/assess_judge_symmetry.py:60`
  - `bench/prompt_eval/tools/generate_judge_audit.py:84,130`

**Impact**
Single provider timeout can abort an entire eval script abruptly (no structured per-case quarantine/retry path).

**Required fix**
Catch `subprocess.TimeoutExpired`, record structured error rows, continue where possible, and surface timeout-rate metrics for gating.

---

### P1-4 — `mode_policy.allow_policy_mutation_mid_cycle=false` is not enforced
**Evidence**
- Policy declares mutation lock: `bench/prompt_eval/config/gate_manifest.v1.json:70-74`.
- No enforcement/read path for `mode_policy.allow_policy_mutation_mid_cycle` in orchestrator (search shows no references).

**Impact**
Threshold/config edits between phases can silently change gate behavior within a cycle.

**Required fix**
Persist a phase-A lockfile of policy/config hashes and verify exact-match before all subsequent phases unless mutation is explicitly allowed.

---

## Final verdict
Status is **not yet promotion-safe** for autonomous real-provider cycles.

Remaining blocker set: **1×P0 + 4×P1**.
