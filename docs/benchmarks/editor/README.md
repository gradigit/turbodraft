# TurboDraft editor benchmarks

This track measures only editor/runtime behavior and excludes model quality scoring.

## Metrics

- `warm_ctrl_g_to_editable_p95_ms`
- `cold_ctrl_g_to_editable_p95_ms`
- `warm_open_roundtrip_p95_ms`
- `warm_save_roundtrip_p95_ms`
- `warm_agent_reflect_p95_ms`
- `warm_textkit_highlight_p95_ms` (microbenchmark only)

## Baseline

- `bench/editor/baseline.json`

## Runner

```sh
python3 scripts/bench_editor_suite.py --path bench/fixtures/dictation_flush_mode.md --warm 50 --cold 8
```

Optional lifecycle matrix:

```sh
python3 scripts/bench_editor_suite.py --with-launch-matrix
```

## True E2E UX runner

```sh
python3 scripts/bench_editor_e2e_ux.py --cold 5 --warm 20
```

## Startup trace runner (primary perf signal)

```sh
python3 scripts/bench_editor_startup_trace.py --cold 10 --warm 40 --min-valid-rate 0.98
```

This reports strict editor-open readiness timings without typing/saving automation overhead.

E2E metrics:

- `ctrlGToTurboDraftActiveMs`
- `ctrlGToEditorWaitReturnMs`
- `ctrlGToHarnessReactivatedMs`
- `ctrlGToTextFocusMs`
- `phaseTurboDraftInteractionMs`
- `phaseReturnToHarnessMs`
- `phaseEndToEndRoundTripMs`

The runner now enforces validity gates and reports p95 from valid runs only.
Recommended production run:

```sh
python3 scripts/bench_editor_e2e_ux.py --cold 10 --warm 30 --min-valid-rate 0.95
```
