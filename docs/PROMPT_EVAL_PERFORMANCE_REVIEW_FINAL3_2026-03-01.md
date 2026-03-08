# Prompt Eval Performance Review — Final3 (2026-03-01)

## Scope
Final targeted review after latest fixes, focused on:
1. mirrored pairwise overhead behavior,
2. budget warning/cap controls (wall-clock, token, cost),
3. residual operational risks.

## Skill used
Used **performance-oracle** workflow for targeted bottleneck and guardrail verification.

## Evidence
- `bench/prompt_eval/reports/final3-mirror-topk0/summary.json`
- `bench/prompt_eval/reports/final3-mirror-topk1/summary.json`
- `bench/prompt_eval/reports/final3-budget-controls-targeted.json`
- `bench/prompt_eval/reports/final3-budget-controls-sim-usage.json`
- `bench/prompt_eval/reports/final3-targeted-performance-snapshot.json`

---

## Executive summary
1. **Mirrored pairwise logic is active and mathematically consistent** with observed call counts.
2. **Budget warnings and hard caps are active** for wall-clock, tokens, and cost (validated via targeted runs).
3. **Largest remaining practical gap** is still enforcement granularity (checks remain phase-boundary based), plus telemetry dependence for token/cost realism.

---

## 1) Mirrored pairwise validation

### Run A (top-k=0)
- Config: `max_cases=1`, `pairwise_top_k=0`, `pairwise_repeats=2`
- Observed `model_call_count`: **11**
- Expected mirrored math: `C*(V + 2*K*R) = 1*(3 + 2*2*2) = 11` ✅
- Pre-mirror math baseline: `1*(3 + 2*2) = 7`
- Mirrored overhead vs pre-mirror: **+57.14%**

### Run B (top-k=1)
- Config: `max_cases=1`, `pairwise_top_k=1`, `pairwise_repeats=2`
- Observed `model_call_count`: **7**
- Expected mirrored math: `1*(3 + 2*1*2) = 7` ✅
- Pre-mirror math baseline: `1*(3 + 1*2) = 5`
- Mirrored overhead vs pre-mirror: **+40.0%**

### Practical impact
- Pruning (`top-k=1`) reduced total calls from **11 → 7** (**-36.36%** vs top-k=0 in this harness).
- Mirroring remains a first-order call multiplier even with pruning.

---

## 2) Budget controls validation

## A) Wall-clock warning + hard cap (native targeted runs)
- Warning scenario (`phase0`, high cap, tiny warning ratio):
  - warning emitted: `BUDGET_WARNING:wall_clock_minutes=0.08/10.00`
- Hard-cap scenario (`phase0`, wall cap=0.01 min):
  - cycle failed with: `budget cap exceeded: wall_clock_minutes=0.06 max=0.01`

## B) Token + cost warning/caps (sim-usage targeted runs)
To validate token/cost controls deterministically, a temporary test fixture usage payload was injected (`usage_totals`) and restored after runs.

- Token warning scenario (`phaseD --simulate-no-provider`, cap=2000, usage=1380):
  - warning emitted: `BUDGET_WARNING:total_tokens=1380/2000`
- Token hard-cap scenario (cap=1000, usage=1380):
  - cycle failed with: `budget cap exceeded: total_tokens=1380 max=1000`
- Cost hard-cap scenario (cap=$0.05, usage=$0.092):
  - cycle failed with: `budget cap exceeded: cost_usd=0.0920 max=0.0500`

## C) Real phaseD caveat observed
A direct real phaseD token-cap attempt failed earlier at promptfoo stage (`promptfoo_eval: rc=100`) before budget cap evaluation, so token/cost cap behavior above was validated with deterministic sim-usage instrumentation.

---

## 3) Residual performance/control risks
1. **Budget enforcement is still phase-boundary based** (not pre-call/in-phase), so a long phase can overshoot before stop.
2. **Token/cost enforcement depends on usage telemetry presence** in summary artifacts.
3. **Mirrored pairwise remains expensive by design**, especially as repeats and challenger count increase.

---

## Final verdict
- **Mirrored pairwise:** working as intended; overhead confirmed and quantifiable.
- **Budget controls:** warning + hard-stop behavior confirmed for wall/token/cost paths.
- **Next highest-value improvement:** move budget checks to in-phase/pre-call guardrails to reduce overshoot risk.

---

## Artifact index
- `bench/prompt_eval/reports/final3-mirror-topk0/summary.json`
- `bench/prompt_eval/reports/final3-mirror-topk1/summary.json`
- `bench/prompt_eval/reports/final3-budget-controls-targeted.json`
- `bench/prompt_eval/reports/final3-budget-controls-sim-usage.json`
- `bench/prompt_eval/reports/final3-targeted-performance-snapshot.json`
