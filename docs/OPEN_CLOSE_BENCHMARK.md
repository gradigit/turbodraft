# TurboDraft Open/Close Benchmark Suite

Production benchmark suite for open/close latency with reliability guardrails.

## Runner

```bash
python3 scripts/bench_open_close_suite.py
```

Default profile:
- cycles: `20`
- warmup excluded from headlines: `1`
- retries per cycle: `2`
- clean slate per cycle: enabled
- primary probe: API-level (always enabled)
- secondary probe: real-agent-CLI user-visible probe (`bench_open_close_real_cli.py`)

## What is measured

### Primary (API-level, CI-safe)
- `apiOpenTotalMs`: trigger to open RPC completion (external API latency)
- `apiCloseTriggerToExitMs`: close trigger (`app.quit` RPC) to `open --wait` process exit
- `apiCycleWallMs`: total cycle wall latency
- internal subcomponents when available:
  - `apiOpenConnectMs`
  - `apiOpenRpcMs`
  - `closeRpcRoundtripMs`
  - `apiCloseTriggerToWaitEventMs` (close trigger to telemetry observation time)
  - `apiCloseWaitMs` (raw `cli_wait.waitMs`, includes pre-close idle time)
  - `apiCloseWaitObservationLagMs` (`apiCloseTriggerToWaitEventMs - apiCloseTriggerToExitMs`)

Interpretation note:
- This suite measures end-to-end CLI/API lifecycle timings for regression tracking.
- These values are not equivalent to the app’s resident window-show latency.
- For user-facing Ctrl+G readiness, use `bench_open_close_real_cli.py`.

### Secondary (user-visible, separate runner)
Run against a real foreground agent CLI window:
- `uiOpenVisibleMs`: keypress to TurboDraft window visible
- `uiOpenReadyMs`: keypress to editor ready-to-type
- `uiCloseDisappearMs`: close command to TurboDraft disappearance

## Reliability contract

- Per-cycle retries on recoverable failures.
- Warmup cycles are excluded from steady-state headline metrics.
- Timestamp ordering validation per cycle.
- Sample-count validation (steady-state successful cycles == primary metric sample counts).
- Outlier detection (IQR 1.5× rule), reported explicitly.
- Optional-probe coverage reported explicitly.
- `runValid=true` only if core validation checks pass.

## Output files

For each run, output directory contains:
- `report.json`: full machine-readable report
- `cycles.jsonl`: raw per-cycle records

JSON format is described by:
- `docs/OPEN_CLOSE_BENCHMARK_SCHEMA.json`

## Reproducible commands

### Local default
```bash
python3 scripts/bench_open_close_suite.py --cycles 20 --warmup 1 --retries 2
```

### Real agent CLI probe (no harness)
Run while your real agent CLI window is frontmost:
```bash
python3 scripts/bench_open_close_real_cli.py --cycles 20 --warmup 1 --poll-ms 2
```
Defaults are optimized for speed (`Cmd+W` close only). Add `--typing-probe` and/or `--save-before-close` for stricter (slower) validation.
If your terminal ignores synthetic Ctrl+G, use `--trigger-mode osascript`.
The report includes `triggerDispatchMs` and post-dispatch adjusted latencies so you can separate key-injection overhead from TurboDraft readiness.
Telemetry correlation is off by default for speed; enable only when needed with `--collect-telemetry` (and tune `--telemetry-timeout-s`).
By default, runs fail when readiness p95 exceeds 80ms (`--gate-metric uiOpenReadyPostDispatchMs --max-ready-p95-ms 80`).

### Single-shot debug probe from `turbodraft` binary
```bash
turbodraft --path /tmp/prompt.md --debug-ready-latency
```
This prints debug metrics to stderr, including `debug_ready_latency_ms` when available.
Optional: `--debug-ready-timeout-ms N` (default `2500`).

### CI / nightly recommended (API-only)
```bash
python3 scripts/bench_open_close_suite.py \
  --cycles 20 \
  --warmup 1 \
  --retries 2 \
  --no-clean-slate \
  --compare tmp/open-close-prev/report.json
```

### Nightly local runner with rolling compare
```bash
scripts/bench_open_close_nightly.sh
```

### Retry/recovery validation (inject one transient failure)
```bash
python3 scripts/bench_open_close_suite.py --cycles 6 --warmup 1 --retries 2 --inject-transient-failure-cycle 2
```

## Methodology and caveats

- API probe is primary KPI and intended for CI/nightly regression tracking.
- User-visible probe is secondary and uses a separate real-CLI runner.
- `apiCloseWaitMs` is retained only as auxiliary telemetry context; headline close KPI is `apiCloseTriggerToExitMs`.
- Keep machine load stable when comparing runs.
- Trend/regression deltas are computed if `--compare` points to a previous report.
- Visual settle analysis is intentionally optional and not a primary KPI.

## Acceptance checklist

- `unrecovered_failures == 0`
- `steady_state_cycle_count > 0`
- `primary_sample_count_ok == true`
- `timestamp_ordering_ok == true`
- warmup excluded from steady-state summaries
- outlier list present
- optional probe coverage present
- if using injected-failure validation: `transient_failure_injected == true` and `transient_failure_recovered == true`

## Freeze record

- `docs/BENCHMARK_FREEZE_2026-02-22.md`
