# TurboDraft Product QA Suite

This is the local regression pack for real product behavior beyond the mandatory T1 editor gate.

## Runner

```bash
scripts/run_product_qa.sh
```

To include the real frontmost-agent Ctrl+G/Ctrl+Q probe:

```bash
RUN_REAL_UI=1 scripts/run_product_qa.sh
```

## What it covers

### Phase 1 — Required editor validation
- `scripts/run_editor_validation.sh`
- includes the mandatory queue/sidebar/drafting workflow tests promoted during T1

### Phase 2 — API open/close regression smoke
- `python3 scripts/bench_open_close_suite.py`
- validates the resident app open/close path with a small steady-state sample
- writes machine-readable artifacts under `tmp/product-qa/.../open-close-api`

### Phase 3 — Attached queue/context API smoke
- `python3 scripts/bench_open_close_suite.py --session-source ... --queue-path ... --context-path ...`
- validates that both the CLI shim and the app accept session attachment metadata during open/close cycles
- writes machine-readable artifacts under `tmp/product-qa/.../open-close-attached`

### Phase 4 — Real Ctrl+G/Ctrl+Q local probe (optional)
- `python3 scripts/bench_open_close_real_cli.py`
- intended for a real frontmost agent CLI window
- disabled by default because it depends on Accessibility and real-window focus conditions
- default `auto` trigger mode prefers low-overhead HID dispatch; override with `REAL_UI_TRIGGER_MODE=osascript` only if your terminal ignores direct Ctrl+G injection
- writes artifacts under `tmp/product-qa/.../open-close-real-cli`

## Default profile

The default runner is intentionally lighter than release/nightly benchmarking:

- API smoke:
  - cycles: `6`
  - warmup: `1`
  - retries: `2`
- attached-session smoke:
  - cycles: `3`
  - warmup: `1`
- real UI probe:
  - cycles: `4`
  - warmup: `1`
  - gate metric: `uiOpenReadyPostDispatchMs`
  - max p95: `80 ms`

Override with env vars if needed:

- `PRODUCT_QA_OUT_DIR`
- `OPEN_CLOSE_CYCLES`
- `OPEN_CLOSE_WARMUP`
- `OPEN_CLOSE_RETRIES`
- `ATTACHED_OPEN_CLOSE_CYCLES`
- `ATTACHED_OPEN_CLOSE_WARMUP`
- `RUN_REAL_UI`
- `REAL_UI_CYCLES`
- `REAL_UI_WARMUP`
- `REAL_UI_POLL_MS`
- `REAL_UI_TRIGGER_MODE`
- `REAL_UI_GATE_METRIC`
- `REAL_UI_MAX_READY_P95_MS`

## Positioning

- Use this for local product QA before release-prep or when validating changes that affect:
  - Ctrl+G open path
  - Ctrl+Q/session close path
  - sidebar/queue integration
  - session attachment handoff (`source`, queue metadata, invoking context)
  - drafting-related editor workflow behavior
- Keep `scripts/run_editor_validation.sh` as the mandatory fast gate.
- Keep the full benchmark commands in `docs/OPEN_CLOSE_BENCHMARK.md` for deeper latency work and trend tracking.
