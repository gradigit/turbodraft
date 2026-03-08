# Claude Second Opinion (claude-opus-4-6 high)


# Production Readiness Second Opinion

## Part 1: Top 8 Remaining Gaps

### G1 — P0: No budget enforcement at runtime
**Impact:** `budget_caps` in gate_manifest (4M tokens, $400, 360 min) are declared but never read or enforced by `phase_orchestrator.py` or `run_codex_prompt_eval.py`. A runaway cycle can burn unlimited spend.
**Fix:** In `phase_orchestrator.py`, load `budget_caps` at cycle start. Wrap each `run_cmd`/`run_codex_exec` call with a cumulative token+cost+wall-clock accumulator. Abort with `BUDGET_EXCEEDED:{resource}` reason code when any cap × `warning_ratio` is hit for warning, or 1.0× for hard stop. Thread the accumulator through every phase function.

### G2 — P0: Subprocess timeout exceptions unhandled
**Impact:** `subprocess.run(..., timeout=timeout_s)` in `run_codex_exec`, `run_codex`, and `run_claude` raises `subprocess.TimeoutExpired` — not caught anywhere. A single slow judge call crashes the entire pipeline with an unstructured traceback and no partial results saved.
**Fix:** Wrap each `subprocess.run` in try/except `subprocess.TimeoutExpired`. On timeout, log the case ID, write a partial result row with `"error": "timeout"`, and continue to the next case. Add a `timeout_count` metric to the summary and a gate check `timeout_rate_max` in the manifest.

### G3 — P0: Holdout isolation declared but never enforced
**Impact:** `mode_policy.enforce_holdout_isolation` is `true` in the manifest but no code reads it. Dev-split cases could leak into holdout, invalidating the entire statistical design.
**Fix:** In `phase_orchestrator.py`, after loading the manifest, assert that dev and holdout dataset paths have zero SHA-256 overlap. At the start of `phase_eval_split`, hash all case IDs per split and reject if intersection is non-empty. Gate this behind the `enforce_holdout_isolation` flag.

### G4 — P1: Non-atomic cache writes create corruption risk
**Impact:** `phase_phaseB` writes calibration/symmetry cache by directly writing to the final path. If two CI runs execute concurrently (e.g., re-triggered workflow), one can read a half-written cache file.
**Fix:** Write to a temp file in the same directory (`{target}.tmp.{pid}`), then `os.replace()` atomically. Add a `cache_version` field inside the JSON so readers can detect schema drift.

### G5 — P1: `invalid_json_rate_max: 0.0` is zero-tolerance
**Impact:** A single malformed judge response (network glitch, model hiccup) fails the entire gate even in non-strict mode, since `judge_invalid_json_rate` is in `blocking_names`.
**Fix:** Set `invalid_json_rate_max` to `0.02` (2%) in the manifest. Alternatively, add 1 automatic retry for invalid JSON before counting it as invalid. Either way, zero-tolerance on a stochastic LLM output is a reliability landmine.

### G6 — P1: `choose_best_variant` uses raw win_rate, ignores CI
**Impact:** A variant with 3 wins / 3 total (100% win rate, CI lower ~0.29) beats one with 80 wins / 100 total (80%, CI lower ~0.71). The promotion gate checks CI later, but `best_variant` selection itself is misleading and could cause the wrong variant to be evaluated in per-family gates.
**Fix:** Change `choose_best_variant` to rank by `ci_wilson_lower(wins, non_tie_n)` instead of raw `win_rate`. This aligns selection with the same statistical rigor used in the gate checks.

### G7 — P1: `provider_contract` import relies on implicit `sys.path`
**Impact:** `from provider_contract import ...` in three files assumes CWD or `PYTHONPATH` includes `bench/prompt_eval/tools/`. Works in CI with explicit `cwd`, but breaks on any local invocation from a different directory — silent `ModuleNotFoundError`.
**Fix:** Add `sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))` at the top of each entry-point script, or convert `tools/` into a proper package with `__init__.py` and use relative imports.

### G8 — P2: `allow_policy_mutation_mid_cycle: false` is unenforced
**Impact:** If the gate manifest is edited between phases (e.g., lowering thresholds after judge calibration passes), the orchestrator silently uses new thresholds — defeating the freeze guarantee.
**Fix:** In `phase_orchestrator.py`, SHA-256 the manifest at cycle start and re-verify before each subsequent phase. If the hash changes and `allow_policy_mutation_mid_cycle` is false, abort with `POLICY_MUTATED_MID_CYCLE` reason code.

---

## Part 2: 6-Step Prioritized Execution Order

| Step | Action | Blocks | Est. Effort |
|------|--------|--------|-------------|
| 1 | **Add timeout exception handling** (G2) to `run_codex_exec`, `run_codex`, `run_claude` | Unblocks all pipeline runs from crashing on transient failures | 1h |
| 2 | **Enforce budget caps** (G1) — add accumulator to orchestrator, wire through phases, add hard-stop | Unblocks safe CI execution | 2h |
| 3 | **Enforce holdout isolation** (G3) — add dataset overlap check at phase start | Unblocks statistical validity of holdout results | 1h |
| 4 | **Fix best-variant selection** (G6) to use CI lower bound, and **fix cache atomicity** (G4) | Unblocks correct promotion decisions and concurrent safety | 1.5h |
| 5 | **Add manifest freeze enforcement** (G8) and **fix import paths** (G7) | Unblocks policy integrity and local dev ergonomics | 1h |
| 6 | **Relax `invalid_json_rate_max`** (G5) to 0.02 or add retry-once — deploy, run one full cycle end-to-end, verify all gates pass on golden fixture data | Final validation | 1h |

---

## Part 3: Top 3 Performance Optimizations

### O1: Parallelize judge calls within pairwise evaluation
**Current:** `run_codex_prompt_eval.py` runs judge calls sequentially — each case × variant × repeat is a blocking subprocess.
**Optimization:** Use `concurrent.futures.ThreadPoolExecutor(max_workers=N)` to fan out judge calls. N should match the `--max-concurrency` value already used for promptfoo (4).
**Risk control:** Add a semaphore tied to the budget accumulator (G1). If cumulative cost exceeds `warning_ratio`, reduce concurrency to 1 and log a warning. Add a `--max-judge-concurrency` CLI flag defaulting to 4, capped at 8.

### O2: Cache-aware judge audit — skip transitivity/shadow/gold if inputs unchanged
**Current:** `generate_judge_audit.py` re-runs all triad, shadow, and gold evaluations every cycle even when datasets and judge prompt haven't changed.
**Optimization:** Compute a composite cache key from `(judge_prompt_sha256, dataset_sha256, model, reasoning_effort)` — the same pattern already used in `phase_phaseB` for calibration. Store audit results in `reports/cache/judge_audit/{key}/`. On cache hit, skip API calls entirely.
**Risk control:** Add a `--no-cache` flag. Log cache key and hit/miss status. Invalidate automatically if gate_manifest version changes. Set TTL of 7 days on cached audit files via a `cached_at` timestamp field.

### O3: Pre-prune variants before generation phase, not just before pairwise
**Current:** `--pairwise-top-k` prunes variants before judge calls, but all variants still go through the full generation phase (expensive drafting calls).
**Optimization:** Add a `--generation-top-k` flag. After running generation for a small sample (e.g., first 10 cases), compute deterministic metrics, prune to top-K, then run remaining cases only for surviving variants.
**Risk control:** Require `--generation-top-k` ≥ `--pairwise-top-k` + 1 (buffer). Log pruned variants and their sample scores. Add a `generation_pruned_variants` field to the summary so reviewers can audit. Default to 0 (disabled) so existing behavior is preserved.

