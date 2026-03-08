# Promptfoo CLI Provider Adversarial Review
Date: 2026-03-02

## Attack Surface / Failure Surface

### A1) CLI hangs or long-tail latency
Risk: deadlocked or stalled eval pipeline.
Mitigation:
- hard subprocess timeouts in provider and orchestrator
- phase-level timeout scaling for heavy judge phases
Status: implemented.

### A2) Non-JSON / malformed event streams
Risk: parser crashes and false positives.
Mitigation:
- best-effort line parsing
- explicit fail-closed `error` payload return
Status: implemented.

### A3) Usage telemetry inconsistency
Risk: budget mis-accounting.
Mitigation:
- usage key normalization (`input/output/total` ↔ `prompt/completion/total`)
- promptfoo stats cost precedence over per-row sum to avoid double counting
Status: implemented.

### A4) Silent-success on failed model execution
Risk: promotion on invalid data.
Mitigation:
- eval runner now exits non-zero when all model calls fail
- orchestrator treats non-zero as phase failure
Status: implemented.

### A5) Holdout leakage via artifacts
Risk: sensitive eval text persistence.
Mitigation:
- redacted mode hashes errors and pairwise payloads.
Status: implemented.

### A6) Promptfoo API-key coupling regression
Risk: keyless local runs break.
Mitigation:
- split configs migrated to CLI provider wrapper
- promptfoo stage can run without OPENAI_API_KEY
Status: implemented.

## Residual Risks
1. Cost telemetry may remain absent for some CLI executions (token-only visibility).
2. Full-size real cycles may require long wall-clock windows depending on judge repeats.

## Recommendation
Ship this migration as default. Keep `--skip-promptfoo` as tactical bypass, not standard path.
