# TurboDraft Benchmark Freeze — February 22, 2026

## Scope
This freeze records the final benchmark figures for:
1. Real user-path Ctrl+G latency (no harness)
2. API benchmark suite (CI-safe)

## Methodology

### A) Real Ctrl+G benchmark (primary UX latency)
- Tool: `scripts/bench_open_close_real_cli.py`
- Trigger path: real key event injection to the frontmost agent CLI window
- Mode used for freeze: `--trigger-mode cgevent` (low trigger overhead)
- No harness process involved
- Warmup cycles excluded from headline stats
- Telemetry correlation disabled for speed (`--collect-telemetry` off)
- Poll cadence: 1 ms
- Timeouts: open/focus/close = 0.3 s each
- Inter-cycle delay: 0.1 s

Freeze command:
```bash
PYTHONPATH=. python3 -m scripts.bench_open_close_real_cli \
  --cycles 52 \
  --warmup 2 \
  --countdown-s 1 \
  --trigger-mode cgevent \
  --poll-ms 1 \
  --open-timeout-s 0.3 \
  --focus-timeout-s 0.3 \
  --close-timeout-s 0.3 \
  --inter-cycle-delay-s 0.1
```

### B) API benchmark suite (primary CI/nightly)
- Tool: `scripts/bench_open_close_suite.py`
- Primary close KPI: `apiCloseTriggerToExitMs`
- Warmup excluded
- Retries enabled for recoverable cycle failures
- Clean-slate per cycle enabled

Freeze commands:
```bash
python3 scripts/bench_open_close_suite.py --cycles 20 --warmup 1 --retries 2 --out-dir tmp/review-freeze-api20
python3 scripts/bench_open_close_suite.py --cycles 40 --warmup 2 --retries 2 --out-dir tmp/review-freeze-api40
```

---

## Final Figures

### 1) Real Ctrl+G (steady-state n=50, run valid)
Source: `tmp/bench_open_close_real_cli_20260222-120339/report.json`

| Metric | Median (ms) | p95 (ms) |
|---|---:|---:|
| Trigger dispatch overhead | 2.54 | 2.60 |
| Keypress → window visible | 53.42 | 70.49 |
| Post-dispatch → window visible | 50.86 | 67.95 |
| Keypress → ready | 57.25 | 71.45 |
| **Post-dispatch → ready** | **54.69** | **68.89** |
| Close command → window disappear | 108.98 | 113.30 |

### 2) API suite, 20-cycle profile (steady-state n=19, run valid)
Source: `tmp/review-freeze-api20/report.json`

| Metric | Median (ms) | p95 (ms) |
|---|---:|---:|
| API open total | 210.13 | 219.28 |
| API close trigger → CLI exit | 134.35 | 154.71 |
| API cycle wall | 364.02 | 385.68 |
| API connect component | 202.86 | 211.66 |
| API open RPC component | 7.24 | 26.83 |
| app.quit RPC component | 58.42 | 80.29 |

### 3) API suite, 40-cycle profile (steady-state n=38, run valid)
Source: `tmp/review-freeze-api40/report.json`

| Metric | Median (ms) | p95 (ms) |
|---|---:|---:|
| API open total | 208.94 | 217.39 |
| API close trigger → CLI exit | 137.66 | 161.72 |
| API cycle wall | 365.98 | 399.92 |
| API connect component | 202.85 | 207.77 |
| API open RPC component | 6.25 | 20.00 |
| app.quit RPC component | 64.27 | 85.70 |

---

## Freeze Interpretation
- Real user-path Ctrl+G readiness is in the ~55 ms median / ~69 ms p95 class when measured with low-overhead trigger mode (`cgevent`).
- API suite is stable across 20-cycle and 40-cycle profiles (medians are consistent).
- For ongoing CI/nightly, use 20-cycle profile.
- For release/freeze decisions, use 40-cycle profile (or repeated 20-cycle runs).

## Gate Policy (locked)
- Real CLI benchmark gate target:
  - metric: `uiOpenReadyPostDispatchMs`
  - threshold: `p95 <= 80 ms`
- This is now the default gate in `bench_open_close_real_cli.py`.

