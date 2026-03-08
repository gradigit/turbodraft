# Codex Second Opinion (gpt-5.3-codex xhigh)

Using **architecture-strategist + performance-oracle** lenses.

## 1) Top 10 production-readiness gaps

| # | Gap | Sev | Impact | Concrete fix |
|---|---|---|---|---|
| 1 | Budget caps defined but not enforced at runtime | **P0** | Runaway cost/time can finish “successfully” but violate policy | Add live token/cost/wall-clock ledger with hard-stop + warn thresholds from manifest |
| 2 | Pairwise judging is order-biased (candidate always A, baseline B) | **P0** | Promotion can be wrong due to positional bias | Run mirrored A/B and B/A judgments; gate on order-effect delta |
| 3 | Selection and significance are on same data (winner’s curse) | **P1** | Inflated false promotions | Pre-register confirmatory variant before holdout, or split holdout into select/confirm |
| 4 | No retry/backoff on model calls | **P1** | Single transient failure aborts full phase | Add retry policy (bounded exponential backoff + jitter) and per-case error quarantine |
| 5 | Cache keys miss code/schema/policy versioning | **P1** | Stale cache can silently invalidate gate outcomes | Include script hash, schema hash, manifest hash, provider config in cache keys |
| 6 | Policy freeze is not enforced across phases | **P1** | Mid-cycle config drift can change outcomes unnoticed | Emit phase-A lockfile of hashes; verify exact match before each later phase |
| 7 | Triad sample floor is global, not per required family | **P1** | Family blind spots can pass transitivity audit | Compute/enforce per-family triad floors and per-family transitivity stats |
| 8 | Provider runner abstraction is partially ignored | **P1** | Harder failover/multi-runner reliability; contract can drift from execution | Route draft/judge calls through runner adapter layer for all roles |
| 9 | No resumable checkpointing at case/variant granularity | **P1** | Crash causes expensive re-runs and longer cycle times | Persist per-case artifacts; resume only missing keys |
| 10 | Weak operational telemetry (request-level latency/tokens/errors) | **P2** | Slow incident response and poor capacity planning | Emit structured per-call telemetry and cycle-level SLO reports |

---

## 2) Prioritized 7-step autonomous execution order

1. **Enforce runtime budget guardrails** (tokens/cost/time) with fail-closed behavior.  
2. **Remove order bias** by mirrored pairwise judging + regression tests.  
3. **Fix statistical protocol** (selection vs confirmation separation).  
4. **Add reliability envelope** (retry/backoff, typed failure handling, partial progress).  
5. **Implement resumable checkpoints + stronger cache versioning**.  
6. **Lock policy/config immutability + per-family audit floors** across phases.  
7. **Add observability + tune throughput** (telemetry-driven concurrency and stopping rules).

---

## 3) Performance optimizations (with risk notes)

1. **Bounded parallel execution for generation/judging/audit**  
   - Gain: major wall-clock reduction.  
   - Risk: rate-limit spikes / correlated failures.  
   - Mitigation: adaptive concurrency + jittered retries.

2. **Content-addressed memoization + resume-by-key**  
   - Gain: avoids rerunning unchanged case/variant/judge work.  
   - Risk: stale reuse if key design is incomplete.  
   - Mitigation: include model, prompt hash, schema hash, script hash, policy hash.

3. **Sequential early stopping for pairwise comparisons**  
   - Gain: cuts expensive judge calls when outcome is already decisive/futile.  
   - Risk: optional-stopping statistical bias.  
   - Mitigation: pre-declared alpha-spending rule and audit log of stop decisions.
