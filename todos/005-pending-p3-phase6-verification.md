# Phase 6 — Verification & Coverage Expansion (Deferred)

**Status:** pending  
**Priority:** p3  
**Tags:** tests, verification, reliability

## Scope

Defer-and-track deeper verification and test coverage expansion.

## Candidate items

- [ ] Add RecoveryStore behavior tests (pruning/dedup/crash-recovery paths)
- [ ] Add FileIO atomic-write/permission-preservation tests
- [ ] Improve app-module testability with dependency injection where practical
- [ ] Run broader performance regression validation after PERF-1/PERF-2 changes

## Exit criteria

- [ ] Coverage improved materially in critical persistence/recovery paths
- [ ] Verification docs updated with evidence (tests/benchmarks)
