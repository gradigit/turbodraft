# Prompt Eval Self-Review (Autonomous Cycle)
Date: 2026-03-02
Cycle ID (full real run): cli-provider-full-20260302

## What was executed
1. Holistic research refresh (OpenAI, Anthropic, Google, Promptfoo primary docs)
2. Adversarial review of orchestration failure modes
3. Pipeline hardening implementation
4. Validation runs (unit + swift + install + phase orchestrator full cycle)

## Primary bug fixed
- Promptfoo assertion-only failures (`rc=100`) were incorrectly treated as hard orchestration failures.
- New behavior:
  - if `rc=100` + valid results + `errors==0` + `failures>0`: normalize to soft failure (`returncode=0`, keep `raw_returncode=100`, attach stats)
  - otherwise remain hard failure.

## Validation evidence
- `python3 -m unittest bench.prompt_eval.tests.test_tools -v` -> 28/28 passed
- `swift test` -> 137/137 passed
- `scripts/install --yes` -> passed
- full real cycle:
  - `python3 bench/prompt_eval/tools/phase_orchestrator.py --phase all --cycle-id cli-provider-full-20260302 ...`
  - all phases A..G succeeded
  - elapsed ~14.96 min

## Performance review
Top slow phases (full real run):
1. phaseB_judge_reliability (~244s)
2. phaseF_holdout (~238s)
3. phaseD_dev (~219s)

Optimization recommendations (from performance review):
- reduce max-cases in inner-loop judge calibration
- pre-prune candidate set before expensive pairwise judging

## Production readiness assessment
Status: **Ready for merge (prompt-eval subsystem changes in this cycle).**

Rationale:
- critical orchestration bug resolved
- regression coverage added
- local CI-equivalent flows pass
- full real cycle reaches phaseG without infrastructure failure

## Remaining non-blocking gaps
1. Cost reporting remains partially unavailable in some CLI paths (`missing_cost_count` > 0).
2. Promotion quality warnings in non-strict runs are expected at low sample counts; strict promotion requires larger datasets and stronger family coverage.
3. Multi-agent execution is currently constrained by environment thread limit; workflows were executed sequentially.

## Follow-up backlog
1. Add optional strict policy to fail when Promptfoo stats include non-zero `errors` even if `rc=100`.
2. Add dedicated metrics extraction for Promptfoo pass/fail rates into phase-level gate dashboards.
3. Add higher-sample nightly run profile for stable strict promotion checks.
