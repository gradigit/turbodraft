# TurboDraft RAM Benchmark Freeze — February 22, 2026

## Scope
This freeze records baseline RAM behavior and gate thresholds for:
- deterministic resident-session memory deltas (`bench_ram_suite.py`)
- CI/nightly RAM regression gating

## Methodology

Tool: `scripts/bench_ram_suite.py`

Primary gate metrics:
1. `peakDeltaResidentMiB` (peak during workload minus idle baseline)
2. `postCloseResidualMiB` (post-close settle minus idle baseline)
3. `memorySlopeMiBPerCycle` (linear slope across steady-state cycles)

Run profile used for freeze:
- cycles: `22`
- warmup: `2`
- retries: `1`
- save iterations per cycle: `8`
- payload bytes per save: `32000`
- sample cadence: `20ms`
- idle settle: `180ms`
- post-close settle: `220ms`
- inter-cycle delay: `0.1s`

Commands:
```bash
python3 scripts/bench_ram_suite.py --cycles 22 --warmup 2 --retries 1 --out-dir tmp/bench_ram_freeze_22
python3 scripts/bench_ram_suite.py --cycles 22 --warmup 2 --retries 1 --out-dir tmp/bench_ram_freeze_22b
```

## Freeze results

### Run A (steady-state n=20)
Source: `tmp/bench_ram_freeze_22/report.json`

| Metric | Median (MiB) | p95 (MiB) |
|---|---:|---:|
| Peak delta (peak-idle) | 14.23 | 25.67 |
| Post-close residual | 9.95 | 25.70 |
| Memory slope (MiB/cycle) | -0.081 | - |

### Run B (steady-state n=20)
Source: `tmp/bench_ram_freeze_22b/report.json`

| Metric | Median (MiB) | p95 (MiB) |
|---|---:|---:|
| Peak delta (peak-idle) | 10.17 | 21.77 |
| Post-close residual | 9.35 | 21.81 |
| Memory slope (MiB/cycle) | 0.215 | - |

## Locked gate thresholds (CI)

- `peakDeltaResidentMiB.p95 <= 32 MiB`
- `postCloseResidualMiB.p95 <= 30 MiB`
- `memorySlopeMiBPerCycle <= 0.8 MiB/cycle`

These thresholds intentionally include headroom for machine variance while still catching meaningful regressions.

## Interpretation notes

- Absolute idle resident memory can drift across long resident runs due to allocator retention and cache behavior.
- Gate decisions should focus on **delta/residual/slope** metrics, not absolute resident values.
