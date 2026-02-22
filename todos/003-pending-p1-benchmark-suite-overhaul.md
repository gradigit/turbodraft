# Prompt Benchmark Suite (Rebuild From Scratch)

**Status:** pending  
**Priority:** p1  
**Tags:** benchmark, prompt-quality, ci

## Context

Legacy prompt-quality benchmark assets were removed from the repo so the suite can be rebuilt cleanly.

Removed (temporary):
- old prompt benchmark scripts
- old prompt benchmark workflow
- old prompt fixtures/baselines/profiles
- old prompt benchmark docs/reports

## Rebuild Requirements

- [ ] Define a new benchmark contract (inputs, outputs, scoring, validity gates)
- [ ] Create new domain-diverse raw fixtures (non-self-referential)
- [ ] Define reviewed baselines or pairwise protocol
- [ ] Implement runner with deterministic JSON output schema
- [ ] Add CI/nightly workflow and regression gates
- [ ] Document methodology, caveats, and reproducible commands

## Acceptance Criteria

- [ ] New prompt-quality suite runs end-to-end locally
- [ ] CI workflow passes on healthy runs
- [ ] Results are reproducible and regression-friendly
- [ ] Documentation reflects the new suite only (no legacy references)
