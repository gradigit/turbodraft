# Prompt Eval Implementation Gap Report (2026-03-01)

Status: **Not production-ready yet**
Scope: Compare target architecture vs current implementation in this repo and define an execution-ready backlog.

## 1) Target architecture to hit

1. **Drafting agent:** Codex Spark (`gpt-5.3-codex-spark`) at `xhigh`.
2. **Primary judge:** Codex 5.3 (`gpt-5.3-codex`) at `xhigh`.
3. **Secondary shadow judge:** Claude Opus 4.6 (`claude-opus-4-6`).
4. **Autonomous multi-phase optimization loop:** end-to-end phases with reliable self-repair, fail-closed promotion, and CI enforcement.

## 2) Current-state snapshot (repo-grounded)

### What is already in place

- Multi-phase orchestrator exists with phases `0/A/B/C/D/E/F/G`:
  - `bench/prompt_eval/tools/phase_orchestrator.py`
- Target model IDs are already present in config:
  - `bench/prompt_eval/config/providers.yaml`
  - `bench/prompt_eval/config/gate_manifest.v1.json`
- Judge reliability toolchain exists (calibration/symmetry/transitivity/shadow/gold):
  - `bench/prompt_eval/calibrate_judge.py`
  - `bench/prompt_eval/assess_judge_symmetry.py`
  - `bench/prompt_eval/tools/generate_judge_audit.py`
- CI workflow scaffolding exists:
  - `.github/workflows/prompt-eval-pr-fast.yml`
  - `.github/workflows/prompt-eval-nightly.yml`
  - `.github/workflows/prompt-eval-holdout.yml`

### Major reality check

- Current datasets are tiny vs gate floors (example: holdout has 3 rows, gate floor is 320 non-tie pairs/family):
  - Datasets: `bench/prompt_eval/datasets/*`
  - Floors: `bench/prompt_eval/config/gate_manifest.v1.json`
- Most automated validation paths rely on simulation, not provider-backed promotion evidence.

## 3) Implementation gaps and weak spots

## P0 (must fix before production)

1. **Policy-to-gate mismatch (declared thresholds not enforced).**
   - `evaluate_gates.py` does not enforce all manifest promotion fields (Holm-adjusted p-value, repeat win-rate stddev, critical-failure ceilings/floors).
   - Files:
     - `bench/prompt_eval/tools/evaluate_gates.py`
     - `bench/prompt_eval/config/gate_manifest.v1.json`

2. **Per-family promotion logic is missing.**
   - Current adjudication picks one global best variant, not independent pass/fail by required preset family.
   - Files:
     - `bench/prompt_eval/run_codex_prompt_eval.py`
     - `bench/prompt_eval/tools/evaluate_gates.py`

3. **Autonomous optimization loop is not actually autonomous yet.**
   - Current orchestration is sequential phase execution with summaries; no durable task queue, lease/heartbeat, dead-letter handling, SAFE/RECOVERY mode transitions, or autonomous retry strategy.
   - File:
     - `bench/prompt_eval/tools/phase_orchestrator.py`

4. **Phase C is lint-only, not candidate generation.**
   - `phaseC_candidate_generation` only checks prompt files exist; no generation/search/optimization loop.
   - File:
     - `bench/prompt_eval/tools/phase_orchestrator.py`

5. **CI promotion path is mostly scaffold-level.**
   - `prompt-promotion.yml` does not run full strict gate adjudication against a real cycle artifact set.
   - File:
     - `.github/workflows/prompt-promotion.yml`

## P1 (high risk, integrity/operability)

6. **Holdout isolation is shallow and bypassable.**
   - Env flag + filename/content checks are weak controls.
   - Files:
     - `bench/prompt_eval/tools/enforce_holdout_isolation.py`
     - `bench/prompt_eval/tools/phase_orchestrator.py`

7. **Holdout secrecy is not production-grade.**
   - Holdout text is in-repo and raw prompts/outputs are stored in artifacts.
   - Files:
     - `bench/prompt_eval/datasets/holdout/*`
     - `bench/prompt_eval/run_codex_prompt_eval.py`

8. **Contracts are declared but not operationally enforced end-to-end.**
   - `environment_contract.v1.json` and budget caps exist, but runtime enforcement is partial.
   - Files:
     - `bench/prompt_eval/config/environment_contract.v1.json`
     - `bench/prompt_eval/config/gate_manifest.v1.json`
     - `bench/prompt_eval/tools/phase_orchestrator.py`

9. **Run-manifest schema integrity is not enforced in pipeline.**
   - Schema exists, but orchestrator does not validate generated manifests against it each phase.
   - Files:
     - `bench/prompt_eval/config/run_manifest.schema.json`
     - `bench/prompt_eval/tools/build_run_manifest.py`
     - `bench/prompt_eval/tools/phase_orchestrator.py`

10. **Provider config is fragmented.**
    - `providers.yaml` is not the single source of truth for runtime model/effort settings.
    - Files:
      - `bench/prompt_eval/config/providers.yaml`
      - hardcoded values in orchestrator/audit scripts

## P2 (quality, reproducibility)

11. **Test coverage is simulation-heavy; limited provider-backed integration coverage.**
    - File:
      - `bench/prompt_eval/tests/test_tools.py`

12. **Judging statistics are still underpowered for truth-level claims.**
    - Current calibration/triad/shadow/gold sets are far below production reliability sample expectations.
    - Files:
      - `bench/prompt_eval/datasets/calibration/*`
      - `bench/prompt_eval/config/gate_manifest.v1.json`

13. **Shadow judge effort is currently configured as `high`, not `xhigh`.**
    - May be intentional for cost/latency, but must be an explicit policy decision and lock.
    - Files:
      - `bench/prompt_eval/config/providers.yaml`
      - `bench/prompt_eval/config/gate_manifest.v1.json`

## 4) Production readiness definition (go/no-go)

Promotion-eligible only when all are true:

1. All manifest thresholds are enforced in gate code (no policy drift).
2. Per-family pass/fail gates enforced for every required family.
3. No simulated artifacts in promotion path.
4. Holdout data and artifacts meet lockbox + redaction policy.
5. Judge reliability passes with real providers and sufficient sample floors.
6. Budget/env contracts are runtime-enforced.
7. Run-manifest and judge-audit artifacts are schema-validated and complete.
8. Provider-backed CI lanes are green with reproducible artifacts.

## 5) Execution-ready backlog (with dependencies + tests)

Legend: Priority `P0 > P1 > P2`

| ID | Priority | Work item | Key deliverables | Depends on |
|---|---|---|---|---|
| B01 | P0 | **Single source of truth runtime config** | Runtime loader for drafter/primary/shadow model+effort from config; remove hardcoded model settings from orchestrator/audit scripts | - |
| B02 | P0 | **Full gate-manifest enforcement parity** | `evaluate_gates.py` enforces all declared promotion/judge keys (incl. Holm, repeat stddev, critical failures/floor) with fail-closed behavior on missing metrics | B01 |
| B03 | P0 | **Per-family gating pipeline** | Family-sliced metrics in eval summaries + per-family gate adjudication across `required_preset_families` | B02 |
| B04 | P0 | **Non-promotable simulation hard-stop** | Global `simulated_artifacts_present` flag propagated to phaseG; strict and non-strict both block promotion when true | B02 |
| B05 | P0 | **Real Phase C candidate generation** | Replace lint-only Phase C with candidate generation lanes (baseline + candidates/family), plus static lint outputs | B01 |
| B06 | P1 | **Holdout lockbox + redaction** | Move holdout source out of repo path; redact sensitive holdout text in persisted artifacts; hash-only identifiers in reports | B03 |
| B07 | P1 | **Strong holdout access control** | Tokenized holdout access service (phase-bound, expiring); global look-budget ledger across cycles | B06 |
| B08 | P1 | **Run-manifest schema enforcement** | `validate_run_manifest.py`; orchestrator fails phase on schema mismatch; phase-specific schema if required | B01 |
| B09 | P1 | **Environment + budget circuit breakers** | Enforce runtime prerequisites and token/cost/time caps with warning+stop behavior from manifest policy | B01 |
| B10 | P1 | **Judge reliability dataset scale-up** | Expand calibration/triad/shadow/gold datasets to meet floor targets and confidence bounds; versioned datasets + hashes | B03 |
| B11 | P1 | **Provider-backed CI lanes** | Split smoke vs promotion-eligible jobs; add codex/claude preflight/auth checks; ensure strict real-provider jobs gate merges/promotions | B04, B07, B09 |
| B12 | P0 | **Promotion workflow implementation** | `prompt-promotion.yml` runs strict phaseG on verified artifacts and emits decision report + rollback-ready outputs | B03, B04, B08, B11 |
| B13 | P2 | **Autonomous repair/state machine** | Attempt budget, reason-code-driven retries, SAFE/SEQUENTIAL/RECOVERY modes, dead-letter handling | B02, B05, B09 |
| B14 | P2 | **Statistical hardening** | CI/p-value confidence reporting, tie-policy sensitivity, reproducibility envelope in gate report | B02, B03, B10 |
| B15 | P2 | **Shadow judge policy finalization** | Decide `high` vs `xhigh` for Claude Opus 4.6 by cost/latency/reliability data and lock in manifest + tests | B01, B10 |

## 6) Dependency execution plan (critical path)

1. **Contracts first:** `B01 -> B02 -> B03 -> B04`
2. **Promotion safety path:** `B06 -> B07`, parallel with `B08/B09`
3. **CI + release path:** `B11 -> B12`
4. **Autonomy hardening:** `B13` after safety/gates are real
5. **Reliability/statistics maturation:** `B10 -> B14 -> B15`

Suggested delivery waves:

- **Wave 1 (blockers):** B01-B05, B12
- **Wave 2 (integrity):** B06-B11
- **Wave 3 (scale/autonomy):** B13-B15

## 7) Test strategy (must ship with backlog)

## A. Contract and gate parity tests

- Unit tests per manifest key: mutate one threshold/metric at a time and assert gate outcome changes as expected.
- Fail-closed tests: missing required metric -> hard fail.
- File targets:
  - `bench/prompt_eval/tools/evaluate_gates.py`
  - `bench/prompt_eval/tests/test_tools.py` (expand)

## B. Family-level correctness tests

- Synthetic multi-family phase summaries where one family fails and others pass; assert overall promotion fails.
- Ensure all `required_preset_families` are present and checked.

## C. Holdout security/integrity tests

- Access tests: out-of-phase holdout read attempts must fail.
- Artifact tests: holdout plaintext must never appear in stored outputs.
- Look-budget tests: repeated holdout attempts across cycle IDs must be blocked by global ledger.

## D. Provider-backed integration tests

- Nightly/provider lane executes real Codex + Claude judge path on bounded calibration sample.
- Assert:
  - real audit mode
  - provider lock compliance
  - schema-valid judge audit and gate artifacts

## E. CI workflow tests

- Smoke workflow: simulated allowed but explicitly non-promotable.
- Promotion workflow: requires real-provider artifacts and strict gate pass.
- Recovery workflow: validates rollback and replay mechanics.

## F. Reliability/statistical tests

- Regression tests for Wilson CI, non-tie handling, Holm correction, repeat-stddev checks.
- Deterministic fixtures for edge cases (all ties, no non-tie pairs, high disagreement, missing families).

## 8) Immediate next 72-hour action list

1. Implement B01 + B02 together (highest leverage, unblocks all).
2. Implement B03 (family-level metrics and gating).
3. Implement B04 (simulation hard-stop for promotion eligibility).
4. Implement B12 minimal strict promotion workflow execution.
5. Add/expand tests for A+B and wire into PR CI.

---

## Bottom line

The repo has a strong scaffold and correct directional architecture, but it still lacks several **production-critical enforcement and autonomy components**. The highest-value path is to close policy-to-gate parity, enforce family-level promotion, block simulated promotion paths, and harden holdout + CI provider-backed execution.
