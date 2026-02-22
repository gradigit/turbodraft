# TurboDraft RAM Benchmark Suite

Production-grade RAM benchmark for repeatable regression tracking.

## Runner

```bash
python3 scripts/bench_ram_suite.py
```

Default profile:
- cycles: `20`
- warmup excluded from headline metrics: `1`
- retries per cycle: `1`
- inter-cycle delay: `0.1s`
- deterministic workload: `8` save iterations, `32KB` payload each
- fixture default: `bench/preambles/core.md`

## What is measured

### Primary (gate-worthy)
- `idleResidentMiB`: resident memory after idle settle window
- `peakDeltaResidentMiB`: `(peak during workload) - (idle baseline)`
- `postCloseResidualMiB`: `(post-close steady resident) - (idle baseline)`
- `memorySlopeMiBPerCycle`: linear slope of peak delta across steady-state cycles

### Secondary diagnostics (optional probes)
- `historySnapshotCountPeak`
- `historySnapshotBytesPeak`
- `stylerCacheEntryPeak`
- `stylerCacheLimit`

Coverage for these probes is reported in `validity.optionalProbeCoverage`.

## Reliability contract

- Warmup cycles are excluded from headline summaries.
- Per-cycle retries are supported for transient failures.
- Timestamp ordering is validated for each successful cycle.
- Primary sample counts must match steady-state successful cycles.
- Outliers are labeled with IQR 1.5× rule.
- Gate checks use outlier-trimmed p95 values when available (falling back to raw p95).
- Run validity is marked false if core checks fail.
- Optional gate enforcement can be enabled with `--enforce-gates`.

## Outputs

Per run:
- `report.json`: aggregated report and validity/gate results
- `cycles.jsonl`: raw per-cycle records

Schema:
- `docs/RAM_BENCHMARK_SCHEMA.json`

## Reproducible commands

### Local default
```bash
python3 scripts/bench_ram_suite.py --cycles 20 --warmup 1 --retries 1
```

### CI gate profile
```bash
python3 scripts/bench_ram_suite.py \
  --cycles 20 \
  --warmup 1 \
  --retries 1 \
  --enforce-gates \
  --max-peak-delta-p95-mib 32 \
  --max-post-close-residual-p95-mib 30 \
  --max-memory-slope-mib-per-cycle 0.8
```

### Nightly deeper profile
```bash
python3 scripts/bench_ram_suite.py \
  --cycles 52 \
  --warmup 2 \
  --retries 2 \
  --save-iterations 12 \
  --payload-bytes 48000 \
  --enforce-gates \
  --max-peak-delta-p95-mib 36 \
  --max-post-close-residual-p95-mib 32 \
  --max-memory-slope-mib-per-cycle 0.8
```

### Compare against previous run
```bash
python3 scripts/bench_ram_suite.py \
  --cycles 20 \
  --warmup 1 \
  --compare tmp/previous-ram/report.json
```

### Transient failure validation
```bash
python3 scripts/bench_ram_suite.py \
  --cycles 6 \
  --warmup 1 \
  --retries 2 \
  --inject-transient-failure-cycle 2
```

## Caveats

- RSS is sampled via process-level polling (`ps rss`), so very short spikes can be missed.
- Use stable machine load when comparing runs.
- Gate thresholds should be tuned from repeated local/CI baselines before tightening.
