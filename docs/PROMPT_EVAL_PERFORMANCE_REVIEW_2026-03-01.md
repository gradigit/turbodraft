# Prompt Eval Performance Review (2026-03-01)

## Scope
Review of runtime + cost implications for the latest prompt-eval pipeline changes, focused on:
- pairwise repeats
- family-level stats
- run/gate manifest validation
- judge audit

## TL;DR
1. **Pairwise repeats are now the largest controllable cost multiplier in D/E/F** (default repeat=5 from gate manifest).
2. **Family stats logic is computationally cheap** (sub-second even at 10x+ current scale); not a bottleneck.
3. **Manifest validation overhead is small** (roughly ~2-3s per full cycle), mostly process-spawn/hash overhead.
4. **Judge audit can dominate phase B wall-clock** once real providers are used; current phase-B cache does not cover judge-audit runs.

---

## Measurement basis

### A) Observed wall-clock from existing real-provider artifacts
- Split phases (D/E/F) from `local-autonomous-cycle-{2,3,4,5}` imply **~14.18s/model-call average** (inferred from call counts vs elapsed).
- Phase B historical:
  - calibration: **~10.99s/call**
  - symmetry: **~20.31s/call**

### B) Current call-count math from code paths
From `run_codex_prompt_eval.py` + `phase_orchestrator.py`:
- Per split calls: `C * (V + K*R)`
  - `C` = cases in split
  - `V` = variants (current default 3)
  - `K` = selected non-baseline variants (default 2 unless top-k pruning)
  - `R` = pairwise repeats (now default 5 via `judge_repeats_min`)

Current pilot datasets:
- dev=4, adversarial=3, holdout=3 (total C=10)
- default (`V=3, K=2, R=5`) => **130 split-phase model calls**
- with top-k=1 => **80 calls**

Phase B current datasets:
- calibration pairs=10 => `3 prompts * 10 = 30 calls`
- symmetry => `2 orientations * repeats(5) * 10 = 100 calls`
- judge audit (triads=6, shadow=7, gold=6) => `3*6 + 2*7 + 6 = 38 calls`
- total Phase B (no cache): **168 calls**

### C) Local microbenchmarks (CPU-only pieces)
- `build_run_manifest.py` mean: **0.145s**
- `validate_run_manifest.py` mean: **0.123s**
- `validate_gate_manifest.py` mean: **0.120s**
- family stats summarization:
  - 5,760 rows: **~0.028s total**
  - 57,600 rows: **~0.229s total**

---

## Component-by-component implications

## 1) Pairwise repeats (runtime/cost impact: **high**)

Default moved to `R=5` (from gate floor), applied to D/E/F by default.

### Runtime/cost effect
- For fixed `C, V, K`, pairwise work scales **linearly with R**.
- With current pilot sizes:
  - `R=1` => 50 calls
  - `R=5` => 130 calls (**2.6x total calls**, +160%)
- Using observed ~14.18s/call, D/E/F estimate:
  - ~30.7 min at default (`130 calls`)

### Risk
- Good for variance control/repeatability, but expensive in early phases where only screening is needed.

## 2) Family stats (runtime/cost impact: **low**)

### Runtime/cost effect
- Pure Python post-processing on already collected results.
- Even 57,600 rows is sub-second in local benchmark.
- No direct model/API cost added.

### Risk
- Main risk is not runtime; it is correctness of family selection logic/stat assumptions.

## 3) Manifest validation (runtime/cost impact: **low**)

### Runtime/cost effect
- Build+validate is ~0.27s/phase locally.
- Across all phases, typically low single-digit seconds.
- No model cost.

### Risk
- Operational overhead is small; fail-closed safety value is high.

## 4) Judge audit (runtime/cost impact: **high**, especially with real providers)

### Runtime/cost effect
- Adds a new phase-B model-call block (`triads + shadow + gold`).
- Current pilot datasets: 38 calls/audit run.
- Phase-B total (calibration + symmetry + audit): 168 calls.
- Using observed per-call ranges, phase B can land around **~48-52 min** uncached.

### Risk
- No cache layer for judge-audit currently in orchestrator; repeated cycles repay this cost.
- If dataset floors are raised, audit runtime scales linearly and can become dominant.

---

## Optimization proposals (concrete, with expected impact + risk)

| Priority | Optimization | Expected Impact | Risk | Notes |
|---|---|---|---|---|
| P0 | **Phase-specific repeat policy** (`D=1, E=2-3, F=5`) | For current pilot: D/E/F calls from 130 -> ~74 to 90 (**~31-43% cut**) | Medium (weaker early-phase reliability) | Keep strict repeats only on holdout promotion phase. |
| P0 | **Cache judge-audit artifacts** (hash key: datasets + prompt + schema + provider contract + script hash) | Repeated cycles save all audit calls (currently 38; floor-scale 210+) | Medium (stale cache risk) | Mirror existing calibration/symmetry cache pattern, but include stronger keying. |
| P1 | **Per-family pruning before pairwise** (not global-only top-k) | Usually cuts pairwise calls ~35-50% when >1 challenger exists | Medium (can prune a true winner in a family) | Add periodic full-run sentinel or exploration budget. |
| P1 | **Adaptive repeat stopping** (early stop once decision confidence/majority is locked) | Typical pairwise reduction ~20-35% | High (optional-stopping bias if not pre-registered) | Must predefine stopping rule and reflect it in gate statistics. |
| P1 | **Bounded concurrency for judge-audit calls** | Wall-clock reduction ~40-65% for audit block (cost unchanged) | Medium (rate limits/transients) | Add retry+jitter and provider-specific concurrency caps. |
| P2 | **In-process manifest build+validate + hash memoization** | Save ~1-2s/cycle | Low | Nice cleanup; not financially meaningful. |
| P2 | **Lean artifact mode for repeats** (store aggregate repeat stats, optionally omit full repeat_decisions) | Lower disk/memory overhead (often 30%+ artifact size cut at higher repeats) | Low/Medium (less forensic detail by default) | Keep full detail behind `--full-audit-artifacts`. |
| P0 | **Token/cost telemetry + budget circuit breaker** | Prevent runaway cost; enables true ROI tuning | Low | `budget_caps` already exist in manifest but are not runtime-enforced. |

---

## Suggested execution order
1. Phase-specific repeat policy (fastest large win).
2. Judge-audit caching (major phase-B win).
3. Per-family pruning.
4. Concurrency for judge-audit.
5. Adaptive stopping (only with pre-registered statistics updates).
6. Low-impact cleanups (manifest process consolidation, lean artifacts).

---

## Practical warning for scale-up
Current floor settings imply very large future workloads if interpreted literally (especially holdout non-tie per-family floors + repeat counts). Without pruning/adaptive policy/concurrency, runtime and cost will grow superlinearly in operational pain even if model-call growth is linear in formulas.

