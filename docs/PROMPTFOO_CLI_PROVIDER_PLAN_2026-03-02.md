# Promptfoo CLI Provider Migration Plan
Date: 2026-03-02
Owner: prompt-eval system
Mode: autonomous

## Objective
Make Promptfoo run keyless by default in this repo by executing local agent CLIs via custom providers, while preserving strict gates and reproducible artifacts.

## Non-Negotiables
1. No regression in gate strictness.
2. No exposure of sensitive holdout text when redaction mode is used.
3. Keep fail-closed behavior on provider failure.
4. Preserve manifest provenance correctness.

## Phases

### Phase 1 — Architecture + Contract
- Add Python provider wrapper for CLI execution.
- Support `runner=codex|claude`, model, effort, timeout.
- Normalize usage to Promptfoo tokenUsage format.
- Emit deterministic error payloads.

Acceptance:
- provider returns `output` on success
- provider returns `error` on failure
- usage mapping present when available

### Phase 2 — Config Migration
- Replace `openai:gpt-5.3-codex-spark` with file-based provider in base/dev/adversarial/holdout configs.
- Keep same prompt/test matrices.

Acceptance:
- `promptfoo validate config` passes for all split configs.

### Phase 3 — Orchestrator Integration
- Keep promptfoo stage enabled by default.
- Keep explicit `--skip-promptfoo` escape hatch for CI resilience.
- Ensure simulation path is deterministic and flag-driven.

Acceptance:
- simulated runs still pass test harness
- non-simulated promptfoo path no longer depends on OPENAI_API_KEY

### Phase 4 — Verification
- Unit tests updated and passing.
- Tooling validators pass.
- Real smoke run (reduced sample) succeeds through D/E/F with promptfoo disabled and with promptfoo path exercised separately.

Acceptance:
- `python3 -m unittest bench.prompt_eval.tests.test_tools -v` green
- `swift test` green
- `scripts/install --yes` green

### Phase 5 — Adversarial hardening
- Validate failure-mode behavior:
  - provider timeout
  - malformed JSON from CLI
  - empty output
  - all model calls fail
- Confirm non-zero exit propagates into orchestrator phase status.

Acceptance:
- fail-closed behavior verified by tests.

## Rollback
- revert provider entries in `config/*.promptfoo.yaml` to previous provider IDs
- remove `providers/promptfoo_cli_provider.py`
- rerun validators
