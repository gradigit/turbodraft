# Prompt Eval Performance Review — Final (2026-03-01)

## Scope
Final post-fix re-check of:
- runtime/cost hotspots in the prompt-eval pipeline
- stability changes after latest fixes

Evidence used:
- `bench/prompt_eval/reports/perf-final-20260301/*`
- `bench/prompt_eval/reports/local-cache-seed/*`
- `bench/prompt_eval/reports/local-cache-hit/*`
- `bench/prompt_eval/reports/local-autonomous-cycle-{4,5}/*`
- `bench/prompt_eval/reports/local-real-provider-check/*`
- local test runs (`python3 -m unittest bench/prompt_eval/tests/test_tools.py`, `swift test`)

---

## Executive verdict

1. **Primary cost hotspot is still model-call volume** (pairwise repeats + judge audit).
2. **Stability improved materially** from fail-closed checks + provider contract enforcement + broader test coverage.
3. **Performance improved partially**: calibration/symmetry cache is a major repeated-run win, but judge audit remains uncached and is now the likely repeated-cycle bottleneck.

---

## Runtime/cost hotspot re-check

## 1) Split evaluation (D/E/F) remains the top cost driver
Current call-count model (from current datasets + gate defaults):
- dev/adversarial/holdout pilot cases: **4 / 3 / 3** (total **10**)
- variants: **3** (baseline + 2 challengers)
- default repeats: **5**

Calls:
- **Default (`top_k=0`, repeats=5): 130 calls**
- **With `top_k=1`: 80 calls**
- **If repeats=1 (`top_k=0`): 50 calls**

Using observed real-provider latency samples (mean **13.74 s/call**, range **11.56–18.84 s/call**):
- D/E/F default projected runtime: **~29.77 min**
- D/E/F with `top_k=1`: **~18.32 min**

**Conclusion:** pairwise repeats are still the largest controllable runtime/cost multiplier.

## 2) Phase B has improved repeated-run performance, but audit still dominates uncached cost
Current phase B call model:
- calibration: **30 calls**
- symmetry: **100 calls**
- judge audit (triad + shadow + gold): **32 calls**
- total uncached: **162 calls**

Projected runtime at 13.74 s/call:
- **uncached phase B: ~37.10 min**
- **with calibration/symmetry cache hit: ~7.33 min** (audit-only)

Observed cache impact (existing real-provider artifacts):
- `local-cache-seed` phase B elapsed: **477.562 s**
- `local-cache-hit` phase B elapsed: **0.039 s**

**Conclusion:** cache works and is highly effective for calibration/symmetry. Remaining hotspot is **uncached judge audit**.

## 3) Local CPU-only overheads are not hotspots
Warm microbench (current code):
- `build_run_manifest.py` mean: **0.0395 s**
- `validate_run_manifest.py` mean: **0.0368 s**
- family stats summarization:
  - **5,760 rows: 0.0046 s mean**
  - **57,600 rows: 0.0765 s mean**

Simulated full cycle (`perf-final-20260301`) phase timings:
- total: **6.597 s**
- slowest phase: **phase0_bootstrap (5.27 s)**

**Conclusion:** manifest/stats logic is cheap; phase0 promptfoo checks are the only notable local overhead.

---

## Stability re-check after latest fixes

## Confirmed improvements

1. **Manifest integrity is more fail-closed**
   - Missing inputs/schema now fail validation paths.
   - `build_run_manifest.py` now hard-fails on missing dataset/config paths.

2. **Provider contract drift is caught earlier**
   - `run_codex_prompt_eval.py` now rejects unsupported runners for drafting/judge_primary.

3. **Scoring correctness improved**
   - Deterministic scoring no longer grants a free mention-any point when no `must_mention_any` constraint exists.

4. **Judge transitivity semantics improved**
   - `generate_judge_audit.py` now tracks/enforces per-family transitivity floor semantics.

5. **Orchestrator timeout handling improved**
   - `run_cmd(...)` now catches `TimeoutExpired` and records rc=124 with logs (reduced crash/hang risk for orchestrated subprocesses).

6. **Regression safety is stronger**
   - Prompt-eval tool tests: **16/16 pass**
   - Swift package tests: **137/137 pass**

## Remaining stability risks

1. **Timeout handling is still incomplete in judge/drafter subprocess helpers**
   - `run_codex_exec`/`run_codex`/`run_claude` paths still rely on uncaught subprocess exceptions in some scripts.

2. **Judge audit remains uncached**
   - Repeated cycles still repay audit model-call cost even when prompt+datasets are unchanged.

3. **`invalid_json_rate_max = 0.0` remains operationally brittle**
   - Any single malformed response can hard-fail reliability checks.

4. **Simulated artifacts correctly block promotion**
   - This is desirable fail-closed behavior, but it means local simulated “all-phase” runs remain non-promotable by design.

---

## Final assessment

- **Did latest changes improve stability?** **Yes (clear improvement).**
- **Did latest changes remove main runtime/cost hotspots?** **Partially.**
  - Major repeated-run win achieved via calibration/symmetry cache.
  - Main remaining cost hotspots are still **pairwise repeats** and **uncached judge audit**.

## Recommended final P0/P1 actions
1. **P0:** Add judge-audit cache keyed by prompt+dataset+schema+provider config hashes.
2. **P0:** Use phase-specific repeat policy (`D=1`, `E=2-3`, `F=5`) to cut inner-loop cost.
3. **P1:** Add bounded retry/backoff + timeout-safe wrappers in all model-call helpers.
4. **P1:** Relax or retry-guard `invalid_json_rate_max` from hard zero-tolerance.

---

## Artifact index
- `bench/prompt_eval/reports/perf-final-20260301/cycle_performance_review.json`
- `bench/prompt_eval/reports/perf-final-20260301/final_perf_snapshot.json`
- `bench/prompt_eval/reports/local-cache-seed/phaseB_judge_reliability/summary.json`
- `bench/prompt_eval/reports/local-cache-hit/phaseB_judge_reliability/summary.json`
- `bench/prompt_eval/reports/local-real-provider-check/phaseD_dev/summary.json`
- `bench/prompt_eval/reports/local-autonomous-cycle-4/phase{D,E,F}_*/summary.json`
- `bench/prompt_eval/reports/local-autonomous-cycle-5/phase{D,E,F}_*/summary.json`
