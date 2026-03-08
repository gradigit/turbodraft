# TurboDraft Prompt-Eval Autonomous Execution Runbook
Date: 2026-03-01
Status: Active

## Objective
Autonomously ship a reliable prompt-eval pipeline with holistic research grounding and fail-closed gates.

## Completion Gates (all required)
1. `validate_gate_manifest.py` passes.
2. `validate_holistic_sources.py` passes:
   - OpenAI + Anthropic + Google + Promptfoo coverage present.
   - Source-count and recent-paper floors pass.
3. Prompt-eval tool tests pass:
   - `python3 -m unittest discover -s bench/prompt_eval/tests -p 'test_*.py'`
4. Phase orchestrator checks pass for:
   - `phase0_bootstrap`
   - `phaseA_policy_freeze`
5. Project install/build passes:
   - `scripts/install --yes`

## Autonomous Loop (per iteration)
1. Implement one focused change set.
2. Run self-review (`tools/self_review.py` + reviewer agent).
3. Run performance review (`tools/performance_review.py` + perf agent).
4. If a new finding appears, run targeted high-quality research and update source artifact.
5. Re-run affected tests and gates.
6. Record artifacts under `bench/prompt_eval/reports/<cycle>/`.

## Guardrails
- Fail closed on manifest/schema violations.
- Keep holdout isolated unless explicit confirmatory mode.
- Never relax source-policy or judge-policy thresholds without updating policy + evidence artifact.

