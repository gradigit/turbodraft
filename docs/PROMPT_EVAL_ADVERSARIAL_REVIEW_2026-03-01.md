# Prompt Eval Adversarial Review (2026-03-01)

## Scope
- **In-scope:** repository artifacts and code under `bench/prompt_eval`, related CI workflows, and generated local report artifacts.
- **Out-of-scope:** external services, unpublished infrastructure, and non-repo assumptions.

## Severity Legend
- **P0 / Critical**: Can directly produce incorrect promotion decisions or invalidate benchmark trust.
- **P1 / High**: Materially weakens integrity; practical exploitation likely.
- **P2 / Medium**: Reliability/traceability weaknesses that can compound into bad decisions.

---

## P0-1 — Policy-to-gate mismatch enables false promotion confidence
**Category:** false-confidence risk, failure mode, governance drift  
**Severity:** P0

### Why this matters
The declared promotion policy is stricter than what gate evaluation actually enforces. This creates a “looks green” failure mode where teams believe policy-compliant promotion happened when it did not.

### Evidence
- Declared policy includes thresholds that are never enforced in gate evaluation:
  - `bench/prompt_eval/config/gate_manifest.v1.json:35-40` (`holm_adjusted_pvalue_max`, `repeat_winrate_stddev_max`, `critical_failures_max`)
  - `bench/prompt_eval/config/gate_manifest.v1.json:43` (`critical_failure_checked_cases_min`)
- Gate evaluator enforces only subset checks (no Holm, no repeat-stddev, no critical-failure gate):
  - `bench/prompt_eval/tools/evaluate_gates.py:137-151`
- Search confirms those policy keys appear only in manifest validation, not in adjudication logic:
  - `bench/prompt_eval/tools/validate_gate_manifest.py:95-106,110-131`

### Concrete mitigations
1. Implement all declared promotion checks in `evaluate_gates.py` (Holm-adjusted p-value, repeat stability, critical-failure ceilings/floors).
2. Fail closed when a declared threshold exists but corresponding metric is missing.
3. Add unit tests that assert each manifest threshold key contributes to pass/fail (`test_tools.py` currently does not cover these keys).

---

## P0-2 — Family-level coverage policy is declared but not enforced
**Category:** gaming vector, false-confidence risk  
**Severity:** P0

### Why this matters
The policy requires preset-family coverage, but adjudication collapses results to global variant-level aggregates. A candidate can win on easier families and still pass despite regressions in other required families.

### Evidence
- Required preset families are declared:
  - `bench/prompt_eval/config/gate_manifest.v1.json:3-13`
- No runtime use of `required_preset_families` outside manifest validation:
  - `bench/prompt_eval/tools/validate_gate_manifest.py:43,56-58`
  - (No usage in gate evaluator/orchestrator)
- Summary aggregation is by variant, not by preset family:
  - `bench/prompt_eval/run_codex_prompt_eval.py:185-225,374-397`
- Best candidate selection is single global best by `win_rate`:
  - `bench/prompt_eval/tools/evaluate_gates.py:24-37,76-94`

### Concrete mitigations
1. Compute and gate on **per-family** outcomes for every family in `required_preset_families`.
2. Require each family to pass independent non-loss + CI floors before global promotion.
3. Add multiplicity control across families in actual gate code (not just policy text).

---

## P0-3 — Non-strict mode can produce fully simulated “green” cycles
**Category:** false-confidence risk, CI fragility  
**Severity:** P0

### Why this matters
A full cycle can report success using simulated artifacts and synthetic metrics. This can be mistaken for real readiness.

### Evidence
- Simulated path short-circuits real provider runs:
  - `bench/prompt_eval/tools/phase_orchestrator.py:205-230,383-396,443`
- Non-strict mode reduces blocking checks to a small judge subset:
  - `bench/prompt_eval/tools/evaluate_gates.py:153-163`
- Simulation fixtures contain large synthetic promotion-friendly stats (`n=400`, `non_tie_n=320`):
  - `bench/prompt_eval/fixtures/split_eval_summary.simulated.json:23-49`
- Generated evidence of non-strict simulated full-pass:
  - `bench/prompt_eval/reports/adversarial-review-sim/cycle_summary.json:2-45`
  - `bench/prompt_eval/reports/adversarial-review-sim/phaseG_promotion/gate_report.json:2-57`

### Concrete mitigations
1. Mark any cycle with simulated artifacts as `non_promotable=true`; force phaseG fail.
2. Remove promotion-like synthetic sample sizes from fixtures (set explicit simulated sentinel metrics instead).
3. For CI, split “smoke” and “promotion-eligible” workflows with distinct status names.

---

## P1-1 — Holdout leakage is built into repo structure and artifacts
**Category:** data leakage, judge/candidate gaming  
**Severity:** P1

### Why this matters
Holdout prompts and constraints are repository-visible, and holdout run artifacts persist full prompts and model outputs. This undermines lockbox assumptions and encourages implicit tuning on holdout content.

### Evidence
- Holdout prompts are in-repo:
  - `bench/prompt_eval/datasets/holdout/cases.jsonl:1-3`
  - `bench/prompt_eval/datasets/holdout/pilot_cases.jsonl:1-3`
- Runner persists raw holdout draft and model output fields:
  - `bench/prompt_eval/run_codex_prompt_eval.py:309-317,399-401`
- Existing holdout artifact contains full `draft_prompt` + `output`:
  - `bench/prompt_eval/reports/local-autonomous-cycle/phaseF_holdout/holdout_eval/generation_results.jsonl:1-6`

### Concrete mitigations
1. Move holdout datasets to access-controlled storage outside repo.
2. Redact holdout text in persisted artifacts (store case hash + metric only).
3. Add pre-commit/CI guard preventing holdout plaintext artifacts from being committed.

---

## P1-2 — Holdout isolation controls are bypassable
**Category:** data leakage, gaming vector  
**Severity:** P1

### Why this matters
Current isolation is shallow (env flag + string checks), and look-budget enforcement is scoped only to a single `cycle_id` directory.

### Evidence
- Isolation checker relies on config filename/content substring + env var:
  - `bench/prompt_eval/tools/enforce_holdout_isolation.py:19-31`
- Orchestrator can self-set allow env via `--allow-holdout`:
  - `bench/prompt_eval/tools/phase_orchestrator.py:449,573-575`
- Look budget counts only manifests under current cycle root:
  - `bench/prompt_eval/tools/phase_orchestrator.py:575-579`

### Concrete mitigations
1. Enforce holdout access through signed tokens tied to identity + dataset hash + expiry.
2. Track holdout look budget globally (not per-cycle folder).
3. Disallow direct holdout dataset paths unless brokered by centralized gate service.

---

## P1-3 — Judge calibration is overfit-prone and weakly independent
**Category:** judge overfitting, non-determinism risk  
**Severity:** P1

### Why this matters
Judge prompt selection and reliability checks rely on tiny datasets with strong overlap risk and no out-of-sample selection discipline.

### Evidence
- Judge prompt is selected on same dataset it is scored on:
  - `bench/prompt_eval/calibrate_judge.py:149-221`
- Symmetry audit defaults to same pair dataset family:
  - `bench/prompt_eval/assess_judge_symmetry.py:101-116,125-153`
- Dataset sizes are very small (effective rows):
  - `bench/prompt_eval/datasets/calibration/judge_pairs.jsonl` (10)
  - `bench/prompt_eval/datasets/calibration/judge_triads.jsonl` (~5)
  - `bench/prompt_eval/datasets/calibration/shadow_spotcheck_pairs.jsonl` (~6)
  - `bench/prompt_eval/datasets/calibration/gold_anchor_pairs.jsonl` (~5)

### Concrete mitigations
1. Split calibration into train/validation/test for prompt selection and independent reliability estimation.
2. Increase and stratify triad/shadow/gold sets to policy floor targets.
3. Report confidence intervals for all reliability metrics and fail on wide intervals.

---

## P1-4 — Nightly CI likely fragile for real-path dependencies
**Category:** CI fragility  
**Severity:** P1

### Why this matters
Nightly invokes real phaseB paths that call `codex` and `claude` CLIs, but workflow does not install/authenticate those CLIs.

### Evidence
- Nightly runs phaseB without `--simulate-no-provider`:
  - `.github/workflows/prompt-eval-nightly.yml:26-31`
- PhaseB invokes scripts that shell out to `codex` and `claude`:
  - `bench/prompt_eval/calibrate_judge.py:33-46`
  - `bench/prompt_eval/assess_judge_symmetry.py:47-59`
  - `bench/prompt_eval/tools/generate_judge_audit.py:62-74,102-115`
- Workflow setup only installs Python + Node:
  - `.github/workflows/prompt-eval-nightly.yml:16-24`

### Concrete mitigations
1. Add explicit installation/auth steps (or preflight checks) for `codex` and `claude` CLIs.
2. Split nightly into deterministic smoke and provider-backed jobs with clear required secrets.
3. Fail fast with actionable diagnostics when required runtime binaries/auth are missing.

---

## P2-1 — Deterministic checks and pre-pruning are gameable
**Category:** gaming vector, false-confidence risk  
**Severity:** P2

### Why this matters
Lexical checks reward keyword/header stuffing; pre-pruning by deterministic score can suppress truly better variants before pairwise judging.

### Evidence
- Deterministic scoring is substring/regex count-based:
  - `bench/prompt_eval/run_codex_prompt_eval.py:92-129`
- Pairwise pre-pruning is keyed on deterministic metrics:
  - `bench/prompt_eval/run_codex_prompt_eval.py:324-338`
- Promptfoo leakage check is narrow token regex only:
  - `bench/prompt_eval/config/dev.promptfoo.yaml:13-17` (and equivalent other split configs)

### Concrete mitigations
1. Require a minimum pairwise budget for every candidate before pruning.
2. Add semantic/structure validators (not just lexical contains).
3. Expand leakage checks to normalized variants (`drafting agent`, unicode separators, etc.).

---

## P2-2 — Symmetry aggregation has tie-break nondeterminism
**Category:** non-determinism  
**Severity:** P2

### Why this matters
`max(set(votes), key=count)` is nondeterministic on tied counts and can yield unstable `forward_mode`/`reverse_mode` outcomes.

### Evidence
- Mode calculation:
  - `bench/prompt_eval/assess_judge_symmetry.py:151-153`

### Concrete mitigations
1. Use deterministic tie-break logic (e.g., sorted frequency with explicit Tie precedence).
2. Require odd repeat counts and record full vote distributions in gate checks.
3. Capture and persist provider request IDs for replay diagnostics.

---

## P2-3 — Run-manifest integrity/provenance is not enforced end-to-end
**Category:** failure mode, traceability risk  
**Severity:** P2

### Why this matters
Schema says manifests must include non-empty dataset/config provenance, but orchestrator writes empty arrays for multiple phases and never validates against schema.

### Evidence
- Schema requires non-empty `dataset_paths` and `config_paths`:
  - `bench/prompt_eval/config/run_manifest.schema.json:51-69`
- Orchestrator emits empty lists for several phases:
  - `bench/prompt_eval/tools/phase_orchestrator.py:494,510,521`
- Example artifact violates schema:
  - `bench/prompt_eval/reports/local-autonomous-cycle/phaseA_policy_freeze/run_manifest.json:12-15`
- No runtime invocation of run-manifest schema validation:
  - `bench/prompt_eval/tools/phase_orchestrator.py` (no validator call)

### Concrete mitigations
1. Add `validate_run_manifest.py` and enforce per phase.
2. Use phase-specific schema variants if empties are intentional.
3. Include actual effective judge prompt/model/dataset hashes from the executed commands.

---

## P2-4 — Declared mode/budget/environment contracts are mostly non-operative
**Category:** false-confidence risk, operations fragility  
**Severity:** P2

### Why this matters
Critical contract fields are validated structurally but not enforced behaviorally.

### Evidence
- Contracts declared:
  - `bench/prompt_eval/config/gate_manifest.v1.json:52-74` (`budget_caps`, `mode_policy`)
  - `bench/prompt_eval/config/environment_contract.v1.json:3-28`
- Runtime does not enforce these caps/policies beyond basic manifest shape checks:
  - `bench/prompt_eval/tools/validate_gate_manifest.py` (schema/value checks only)
  - `bench/prompt_eval/tools/phase_orchestrator.py:140-152` (phase0 checks omit env/budget/policy mutation enforcement)

### Concrete mitigations
1. Enforce environment contract at phase0 (required env + runtime version checks).
2. Snapshot frozen policy hash at phaseA and verify unchanged across subsequent phases.
3. Aggregate token/cost from usage telemetry and fail/warn against `budget_caps`.

---

## Priority Remediation Order
1. **Immediate (blocker):** P0-1, P0-2, P0-3
2. **Next (integrity hardening):** P1-1, P1-2, P1-3
3. **Stability/operability:** P1-4, P2-* findings

## Reviewer note
A full simulated cycle (`adversarial-review-sim`) was executed during this review solely to validate current control behavior; artifacts are under `bench/prompt_eval/reports/adversarial-review-sim/` and `.../adversarial-review-sim-strict/`.
