# Phase 5 — Cleanup Batch (Deferred)

**Status:** pending  
**Priority:** p2  
**Tags:** cleanup, simplification

## Scope

Defer-and-track simplification/dead-code cleanup from production readiness review.

## Candidate items

- [ ] Remove dead `CodexCLIAgentAdapter.swift` path if still unused
- [ ] Remove stale `TURBODRAFT_USE_CODEEDIT_TEXTVIEW` spike code
- [ ] Simplify vestigial theme surface (inline/remove low-value abstractions)
- [ ] Continue dead-function removal identified in review
- [ ] Re-evaluate built-in theme count vs JSON-shipped themes

## Exit criteria

- [ ] LOC reduction delivered without behavior regressions
- [ ] Tests + install pass
