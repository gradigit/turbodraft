# Prompt Eval In-between Optimization Plan
Date: 2026-03-01
Status: Integrated into autonomous pipeline

## Trigger
Cycle performance review identified slow phases:
- phaseB_judge_reliability
- phaseF_holdout
- phaseD_dev

## Applied optimizations
1. Added judge reliability cache keyed by dataset + judge prompt hashes.
2. Added pairwise pre-pruning option (`--pairwise-top-k`) to reduce expensive pairwise judge calls.
3. Added cycle-level performance review artifact and recommendations.
4. Added strict split-integrity checks with canonical split files.

## New intermediate goals
1. Keep Phase B under 120s on cache hit.
2. Keep dev/adversarial pairwise calls bounded by pre-pruned variant set.
3. Ensure every cycle emits `cycle_performance_review.json` and actionable recommendations.

## Validation hooks
- `bench/prompt_eval/tools/performance_review.py`
- `bench/prompt_eval/tools/phase_orchestrator.py`
- `bench/prompt_eval/tests/test_tools.py`

## Next optimization backlog
1. Add delta-only judge calibration on changed cases.
2. Add async parallel execution lanes for preset-family candidate generation.
3. Add explicit token/cost ledger collection into gate reports.
