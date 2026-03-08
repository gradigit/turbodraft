# Prompt Eval Performance Review — Final2 (2026-03-01)

## Scope
Post-fix performance review focused on:
1. budget enforcement behavior and overhead,
2. pairwise mirrored judging overhead,
3. timeout handling impact.

This updates `PROMPT_EVAL_PERFORMANCE_REVIEW_FINAL_2026-03-01.md` using current code paths plus post-fix validation runs.

---

## Executive summary

1. **Budget caps are now enforced** for wall-clock, token, and cost caps at cycle runtime; this is a material safety improvement.
2. **Mirrored pairwise judging is now the dominant controllable multiplier** in split phases (D/E/F), increasing split call volume by **+76.9%** vs pre-mirror math at current defaults.
3. **Timeout handling is substantially more resilient** (timeouts are quarantined and surfaced instead of hard-crashing key flows), but timeout-heavy runs can still burn large wall-clock because enforcement is phase-boundary-based.

---

## Evidence used

### A) Code-path checks
- `bench/prompt_eval/tools/phase_orchestrator.py`
  - runtime budget checks after each phase (`cycle_max_wall_clock_minutes`, `cycle_max_tokens`, `cycle_max_cost_usd`)
  - `run_cmd(...)` timeout handling returns `rc=124`
- `bench/prompt_eval/run_codex_prompt_eval.py`
  - mirrored pairwise execution (forward A/B + reverse B/A)
  - per-call exception quarantine in generation and pairwise loops
- `bench/prompt_eval/tools/generate_judge_audit.py`
  - `safe_run_primary` / `safe_run_shadow` quarantine failures (including timeout exceptions)

### B) Post-fix validation runs (local)
- wall-clock cap enforcement repro:
  - `bench/prompt_eval/reports/test-budget-enforce-fb4b308c/cycle_summary.json`
  - observed error: `budget cap exceeded: wall_clock_minutes=0.07 max=0.01`
- token cap enforcement repro:
  - `bench/prompt_eval/reports/test-budget-tokens-acbcdb65/cycle_summary.json`
  - observed error: `budget cap exceeded: total_tokens=1380 max=1000`
  - usage source: `bench/prompt_eval/reports/test-budget-tokens-acbcdb65/phaseD_dev/dev_eval/summary.json`
- warning-ratio behavior check:
  - `bench/prompt_eval/reports/test-budget-warning-32a06d70/cycle_summary.json`
  - run succeeds with no warning payload despite `warning_ratio=0.1` test configuration

### C) Existing runtime baseline artifact
- `bench/prompt_eval/reports/perf-final-20260301/final_perf_snapshot.json`
  - mean sec/call used for projections: **13.7401**

---

## 1) Budget enforcement: impact and overhead

## What is fixed
Budget caps are now active in orchestrator runtime (not just declared in policy):
- wall-clock hard stop,
- token hard stop,
- cost hard stop.

Both wall-clock and token enforcement are reproducibly triggered in post-fix local tests (artifacts above).

## Performance overhead
Overhead of checks themselves is negligible (simple scalar comparisons + optional summary JSON read per phase). No meaningful cost increase relative to model-call work.

## Remaining behavior gap
- `warning_ratio` is validated in manifest schema but not operationally used as a soft-throttle/early-warning mechanism.
- Budget checks execute **after each phase completes**, so a long phase can overshoot budget before stop.

---

## 2) Pairwise mirrored judging overhead

## New call-count model (D/E/F)
Current implementation performs mirrored judging per repeat:
- per case split calls = `V + 2*K*R`
  - `V`: variants
  - `K`: selected non-baseline challengers
  - `R`: repeats

With current pilot sizes (`C=10`, `V=3`, `K=2`, `R=5`):
- **Pre-mirror math**: `C*(V + K*R) = 130`
- **Current mirrored math**: `C*(V + 2*K*R) = 230`
- **Delta**: `+100` calls (**+76.9%**) for split phases.

Using mean 13.7401 s/call:
- split runtime projection moves from **29.77 min → 52.67 min**.

Including uncached phase B (168 calls), total rises:
- **68.24 min → 91.14 min** (**+33.6% total calls**).

## Empirical harness sanity-check (1-case synthetic run)
- top-k=0: **23 calls**
- top-k=1: **13 calls**
- observed reduction: **-43.5%**, matching mirrored formula expectations.

## Practical implication
Mirroring improves bias resistance but is now a first-order budget driver. Default repeat and challenger settings should be budget-aware per phase.

---

## 3) Timeout handling impact

## What improved
- Orchestrator command wrapper now converts subprocess timeouts into structured failure (`rc=124`) with timeout marker logs.
- Split eval and judge-audit flows now quarantine per-call exceptions instead of failing the whole run immediately in common timeout scenarios.

Synthetic timeout test (1 case, 2 variants, timeout=1s, fake slow provider) completed with:
- process return code `0` (run survived),
- generation rows containing timeout errors,
- pairwise decision downgraded to `Tie` with structured error payload.

## Performance impact
- Success-path overhead from timeout guards is negligible.
- Failure-path wall-clock can still be high because each timeout consumes full `--timeout` budget.
- Mirroring doubles timeout exposure for pairwise comparisons (forward + reverse).

Worst-case timeout envelope at defaults (`C=10`, `V=3`, `K=2`, `R=5`, timeout=240s):
- generation: `30 * 240s = 120 min`
- mirrored pairwise: `200 * 240s = 800 min`
- split total worst case: **920 min** (pre-budget-stop if phase runs to completion)

This exceeds the 360-minute cycle cap unless budget checks are made more granular than phase boundaries.

---

## Updated optimization recommendations

## P0 (highest)
1. **Make budget control in-phase, not just post-phase**
   - pre-call guard using remaining wall/token/cost budget,
   - emit explicit reason codes,
   - stop launching new model calls once remaining budget is insufficient.

2. **Operationalize `warning_ratio`**
   - at warning threshold: auto-throttle concurrency, reduce repeats/top-k, and log budget warning events in `cycle_summary`.

3. **Phase-specific mirrored policy**
   - keep strict mirroring for holdout/promotion path,
   - use reduced repeats and/or sampled mirroring in dev/adversarial inner loops.

## P1
4. **Bound timeout blast radius per pair**
   - use a shared per-pair timeout budget (forward+reverse),
   - if forward times out, skip reverse (or short reverse fallback) to avoid 2x timeout burn.

5. **Add timeout-rate telemetry and gates**
   - `timeout_count`, `timeout_rate`, and per-phase timeout metrics,
   - optional gate threshold to block promotion when judge reliability degrades via timeouts.

6. **Cache judge-audit artifacts**
   - keep current calibration/symmetry cache,
   - add audit cache keyed by prompt/dataset/provider/schema hashes.

## P2
7. **Fallback budget estimation when usage telemetry missing**
   - if usage not present, estimate from call counts and per-model priors to avoid blind token/cost accounting.

8. **Expose budget burn-down in artifacts**
   - write phase-by-phase remaining budget ledger to aid CI triage and tuning.

---

## Final verdict
Post-fix status is improved and safer:
- **budget hard-stops now work**,
- **timeout handling is more robust**,
- but **mirrored pairwise overhead is now a major budget/runtime factor**.

Next performance wins should prioritize **in-phase budget control + mirrored-cost governance + timeout blast-radius reduction**.
