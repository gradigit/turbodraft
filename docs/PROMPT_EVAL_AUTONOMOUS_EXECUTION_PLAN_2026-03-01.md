# TurboDraft Autonomous Prompt-Eval Execution Plan (Research + Adversarial Hardened)
Date: 2026-03-01
Status: Active execution plan
Owner: Prompt Evaluation Orchestrator (Codex CLI, multi-agent)

## 1) Objective
Ship production-grade prompt-engineering presets with defendable quality gains, using:
- **drafting_agent model:** `gpt-5.3-codex-spark` (`xhigh`)
- **primary judge:** `gpt-5.3-codex` (`xhigh`)
- **secondary shadow judge:** `claude-opus-4-6` (Claude Code CLI, `high` effort)

No promotion is allowed without strict gate pass and real-provider judge-audit evidence.

## 2) Inputs used to build this plan
- Research refresh (2025-06+ official/provider + recent literature):
  - `docs/PROMPT_EVAL_RESEARCH_REFRESH_2026-03-01.md`
- Adversarial architecture audit:
  - `docs/PROMPT_EVAL_ADVERSARIAL_REVIEW_2026-03-01.md`
- Implementation gap report:
  - `docs/PROMPT_EVAL_IMPLEMENTATION_GAP_2026-03-01.md`

## 3) Hard invariants
1. Holdout lockbox isolation (no tuning on holdout data).
2. Promotion requires strict phaseG pass.
3. Simulated artifacts are never promotable.
4. Provider lock must match policy (primary + shadow judge).
5. Gate thresholds are fail-closed (missing required metrics => fail).
6. Required preset-family coverage is enforced at gate time.

## 4) Runtime architecture
## 4.1 Control plane
- `phase_orchestrator.py` controls phases `0/A/B/C/D/E/F/G`.
- Every phase emits:
  - phase summary,
  - self-review,
  - run manifest (schema validated),
  - logs.

## 4.2 Evaluation plane
- `run_codex_prompt_eval.py`
  - generates prompt outputs,
  - runs deterministic contract checks,
  - runs pairwise judge evaluations,
  - emits family-level summary and promotion statistics.

## 4.3 Judge reliability plane
- `calibrate_judge.py` (judge prompt selection)
- `assess_judge_symmetry.py` (swap symmetry + repeat agreement)
- `generate_judge_audit.py` (transitivity + shadow drift + gold anchors)

## 4.4 Gate plane
- `evaluate_gates.py` adjudicates strict pass/fail with:
  - judge reliability thresholds,
  - per-family promotion thresholds,
  - Holm-adjusted p-value,
  - repeat-winrate stddev,
  - critical failure floor/ceiling,
  - simulated-artifact ban.

## 5) Multi-agent autonomous workflow
For each cycle:
1. **Research agent swarm**
   - refresh evidence for any newly discovered failure mode.
2. **Adversarial agent swarm**
   - attempt gaming/leakage/false-confidence attacks.
3. **Implementation workers**
   - patch gate/runner/orchestrator components.
4. **Verification awaiter**
   - long-running test/eval commands and artifact checks.
5. **Performance reviewer**
   - check run-time/cost/variance and suggest optimizations.

## 6) Phase entry/exit criteria
## Phase 0 (bootstrap)
Entry: none
Exit:
- gate manifest valid
- holistic source policy valid
- datasets pass integrity checks
- promptfoo configs valid

## Phase A (policy freeze)
Entry: phase0 pass
Exit:
- required architecture docs exist
- policy artifacts immutable for this cycle

## Phase B (judge reliability)
Entry: phaseA pass
Exit:
- calibration summary produced
- symmetry summary produced
- judge audit produced
- provider lock evidence recorded

## Phase C (candidate generation)
Entry: phaseB pass
Exit:
- candidate registry valid
- required prompt assets present

## Phase D (dev split)
Entry: phaseC pass
Exit:
- dev split eval artifacts generated

## Phase E (adversarial split)
Entry: phaseD pass
Exit:
- adversarial split eval artifacts generated

## Phase F (holdout split)
Entry: phaseE pass + holdout access enabled
Exit:
- holdout eval artifacts generated
- holdout look budget respected

## Phase G (promotion)
Entry: phaseB + phaseF artifacts available
Exit (strict):
- all strict checks pass
- no simulated artifacts
- per-family gates pass

## 7) Scoring and decision model
## 7.1 Family-level winner selection
Per required family:
- pick best non-baseline candidate by pairwise `win_rate`.
- evaluate per-family:
  - non-loss rate,
  - Wilson CI lower bound,
  - non-tie sample floor.

## 7.2 Cross-family promotion statistics
- one-sided exact binomial p-values per family.
- Holm adjustment across family p-values.
- repeat win-rate standard deviation ceiling.
- critical failure count/floor checks.

## 8) Self-repair strategy
If a phase fails:
1. classify failure (`schema`, `provider`, `sample_floor`, `leakage`, `statistical`).
2. apply targeted patch set.
3. rerun only affected phase(s) + downstream dependencies.
4. stop if failure repeats without net metric improvement.

## 9) Completion criteria
A cycle is complete only if:
- strict phaseG passes,
- all required families satisfy promotion criteria,
- judge audit is real-provider and provider-lock compliant,
- reports/manifests/schema checks are all green.

## 10) Immediate execution queue
1. Expand datasets to hit sample floors (dev/adversarial/holdout + calibration triad/shadow/gold).
2. Execute real-provider phase B with locked providers.
3. Execute full strict cycle on expanded holdout.
4. Promote only if strict gate report is fully green.
