# Prompt Eval Self-Review (2026-03-01)

## Scope
Reviewed:
- `bench/prompt_eval/run_codex_prompt_eval.py`
- `bench/prompt_eval/tools/phase_orchestrator.py`
- `bench/prompt_eval/tools/evaluate_gates.py`
- `bench/prompt_eval/tools/generate_judge_audit.py`
- `bench/prompt_eval/tools/validate_run_manifest.py`
- `bench/prompt_eval/config/providers.v1.json`

Focus areas: correctness bugs, fail-open paths, schema mismatches, CI break risks.

## Severity-ranked findings

| Severity | Area | Finding |
|---|---|---|
| **P1 (High)** | Manifest integrity / fail-open | `run_manifest` validation can pass even when dataset/config paths are missing and unhashed. |
| **P1 (High)** | Schema enforcement | `validate_run_manifest.py` accepts `--schema` but never validates against that schema. |
| **P1 (High)** | Provider contract mismatch | Provider `runner` is declared in config but ignored by eval runner; execution is hardcoded to Codex. |
| **P2 (Medium)** | Correctness scoring | Deterministic score includes a free “mention-any” point even when no `must_mention_any` constraint exists. |
| **P2 (Medium)** | Gate semantics mismatch | Judge transitivity sample floor is enforced globally, not per-family (despite `*_per_family_min` threshold key). |
| **P2 (Medium)** | CI reliability | Orchestrator subprocesses run without timeouts; hung child process can stall CI jobs. |

---

## 1) P1 — Manifest integrity can fail open on missing/unhashed paths

**References**
- `bench/prompt_eval/tools/build_run_manifest.py:47-48`
- `bench/prompt_eval/tools/validate_run_manifest.py:79-113`

**Problem**
- Manifest builder only hashes paths that exist (`if p.exists()`), so missing files stay in `dataset_paths` / `config_paths` without corresponding hashes.
- Validator checks only that arrays/objects are non-empty; it does **not** enforce 1:1 coverage between `*_paths` and `*_hashes`, and does not require each referenced path to exist.

**Impact**
- Provenance can look valid (`ok: true`) while containing unresolved or tampered inputs.
- Violates fail-closed expectations for run manifests.

**Observed behavior (repro)**
- Built manifest with dataset path `/tmp/DOES_NOT_EXIST` and validated it; validator still returned `ok: true`.

**Fix**
1. In builder, hard-fail if any provided dataset/config path does not exist.
2. In validator, enforce:
   - all paths exist,
   - all paths are absolute,
   - `set(dataset_paths) == set(dataset_hashes.keys())`,
   - `set(config_paths) == set(config_hashes.keys())`.
3. Optionally verify hash values by recomputing for each path during validation.

---

## 2) P1 — `--schema` is currently non-functional in `validate_run_manifest.py`

**References**
- `bench/prompt_eval/tools/validate_run_manifest.py:159`
- `bench/prompt_eval/tools/validate_run_manifest.py:172`
- `bench/prompt_eval/tools/validate_run_manifest.py:167-168`

**Problem**
- CLI exposes `--schema`, and output echoes schema path, but code never loads or validates against the schema.

**Impact**
- False confidence: schema drift or incompatible manifests are not caught by the schema contract.
- Easy CI blind spot if manual validator logic diverges from `run_manifest.schema.json`.

**Observed behavior (repro)**
- Validation still returned `ok: true` when called with `--schema /definitely/missing/schema.json`.

**Fix**
- Load schema file and perform JSON Schema validation (e.g., `jsonschema` Draft 2020-12).
- Hard-fail when schema file is missing/unreadable.
- Keep manual domain checks as additive constraints, not a schema replacement.

---

## 3) P1 — Provider contract `runner` is ignored in core eval path

**References**
- `bench/prompt_eval/config/providers.v1.json:4-18`
- `bench/prompt_eval/run_codex_prompt_eval.py:34-48`
- `bench/prompt_eval/run_codex_prompt_eval.py:385-393`

**Problem**
- Provider contract includes `runner` per role, but `run_codex_prompt_eval.py` always shells out to `codex exec` for both draft and judge.
- Only `model` + `reasoning_effort` are consumed from provider contract.

**Impact**
- Contract/schema mismatch: changing `runner` in provider config does not change behavior.
- Misconfiguration can silently run with the wrong backend until downstream checks fail.

**Fix**
- Either:
  1. Explicitly enforce `runner == "codex"` for drafting/judge_primary and fail closed otherwise, **or**
  2. Implement runner-dispatched execution (`codex`, `claude`, etc.) and use provider role configs consistently.

---

## 4) P2 — Deterministic score is inflated by unconditional mention-any point

**References**
- `bench/prompt_eval/run_codex_prompt_eval.py:109-123`

**Problem**
- Score denominator always adds `+1` for mention-any check (`total_checks = ... + 1 + ...`), even when `must_mention_any` is empty.
- In those cases, `mention_any_ok` defaults `True`, so each case gets an unconditional pass point.

**Impact**
- Score inflation and cross-case comparability distortion.
- Can affect pre-pruning (`--pairwise-top-k`) since deterministic stats drive ranking.

**Fix**
- Gate mention-any accounting behind presence of constraint:
  - `mention_check = 1 if must_mention_any else 0`
  - add to `total_checks` and `passed_checks` only when `mention_check == 1`.

---

## 5) P2 — Judge transitivity floor logic is global, not per family

**References**
- `bench/prompt_eval/tools/generate_judge_audit.py:333-337`
- `bench/prompt_eval/config/gate_manifest.v1.json:47`

**Problem**
- Code checks `triads_with_chain >= judge_triads_per_family_min` once globally.
- Threshold name is explicitly per-family (`judge_triads_per_family_min`), but no per-family accounting is enforced.

**Impact**
- Potential pass with uneven family coverage (fail-open relative to policy semantics).

**Fix**
- Aggregate triad chain counts by `preset` and enforce floor for every required family.
- Emit explicit reason codes per family on floor failures.

---

## 6) P2 — Orchestrator subprocesses have no timeout guards

**References**
- `bench/prompt_eval/tools/phase_orchestrator.py:34`
- `bench/prompt_eval/tools/phase_orchestrator.py:779-790`

**Problem**
- `subprocess.run(..., capture_output=True)` is called without `timeout` in common orchestration paths.

**Impact**
- Hung external tools (network stalls, CLI deadlocks) can block phase completion and burn CI minutes.

**Fix**
- Add timeout parameter to `run_cmd` and enforce per-command defaults.
- Include timeout in logs/reason codes; treat timeout as hard failure with explicit RC classification.

---

## Quick patch order recommendation
1. **First**: Fix manifest fail-open + schema enforcement (`validate_run_manifest.py`, `build_run_manifest.py`).
2. **Second**: Resolve provider contract mismatch (either fail-closed codex-only guard or runner dispatch implementation).
3. **Third**: Correct deterministic score math and per-family transitivity floor.
4. **Fourth**: Add orchestrator timeouts for CI stability.

