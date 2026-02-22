# RAM Benchmark + Regression Gate Rollout Plan

Execution source: Epic #19 (phases #12-#18)

- [x] Phase 0: Define RAM benchmark contract + schema docs
- [x] Phase 1: Add memory sampler/phase instrumentation + optional diagnostics
- [x] Phase 2: Implement deterministic RAM benchmark runner with per-cycle JSON output
- [x] Phase 3: Add regression gate checks and CI/nightly integration
- [x] Phase 4: Port useful PR #11 memory fixes safely on top of current main
- [x] Phase 5: Tune thresholds + produce baseline freeze record
- [x] Phase 6: Harden suite (outliers, transient failure recovery, trend artifacts)

## Validation
- [x] swift test
- [x] scripts/install
- [x] RAM benchmark smoke run
