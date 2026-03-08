# Prompt Eval Adversarial Review (Cycle: 2026-03-02)
Date: 2026-03-02
Mode: Autonomous

## Inputs reviewed
- Current prompt-eval tooling and tests under `bench/prompt_eval/tools` and `bench/prompt_eval/tests`
- Recent E2E run artifacts for `cli-provider-e2e-20260302`
- Promptfoo CLI behavior in local execution

## Critical finding
### F1: Promptfoo assertion failures are incorrectly treated as infrastructure failures
Observed in `phaseD_dev` run:
- promptfoo completed and wrote valid results JSON
- results included pass/fail counts (`9 passed, 3 failed, 0 errors`)
- process return code was `100`
- orchestrator immediately raised `phaseD promptfoo failed: rc=100`

Risk:
- false pipeline abort despite successful evaluation artifact generation
- blocks autonomous improvement loops from consuming evaluation signal
- increases CI brittleness when expected rubric failures occur during experimentation

## Why this matters
Prompt engineering evaluation requires failing candidates to be measured, not treated as transport/runtime errors. Assertion failure is expected during search. Infrastructure failure is not.

Conflating the two causes:
- reduced throughput
- unstable automation
- misleading error reports

## Remediation policy
1. Distinguish Promptfoo return codes by semantics:
   - **hard failure**: command/runtime/provider errors (non-100, or missing/invalid output)
   - **soft evaluation failure**: rc=100 with valid promptfoo results containing test failures
2. Preserve both values in metadata:
   - `returncode` normalized for orchestration continuation
   - `raw_returncode` for forensic accuracy
   - `evaluation_failures` stats from results file
3. Keep fail-closed for real execution errors.

## Additional adversarial checks
- If rc=100 and results file missing -> hard fail (cannot trust state)
- If rc=100 and results parse fails -> hard fail
- If stats show `errors > 0` and provider-level errors dominate, consider policy hook to fail phase explicitly

## Residual risks
- Promptfoo may change exit code conventions in future versions.
Mitigation: assert behavior in unit tests with controlled fixtures and add a guard in release checklist.

## Decision
Implement rc=100 soft-failure normalization with explicit stats extraction and tests.
