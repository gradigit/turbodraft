# PromptPad A/B: Earliest baseline vs current (all changes)

- Baseline artifact: docs/benchmarks/optimization-runs/2026-02-17T03-43-25-baseline/summary.json
- Current artifact: docs/benchmarks/optimization-runs/2026-02-17T11-16-38-final-like-baseline/summary.json

## Harness parity

- fixture: /Users/aaaaa/Projects/promptpad/bench/fixtures/dictation_flush_mode.md == /Users/aaaaa/Projects/promptpad/bench/fixtures/dictation_flush_mode.md
- warm: 3 == 3
- cold: 1 == 1

## Command latency A/B (ms)

| Metric | baseline | current | delta |
|---|---:|---:|---:|
| warm promptpad open p50 | 9.72 | 18.64 | +8.92 |
| warm promptpad open p95 | 9.72 | 18.64 | +8.92 |
| warm promptpad-open p50 | NA | 12.16 | NA |
| warm promptpad-open p95 | NA | 12.16 | NA |
| cold promptpad open p50 | NA | 185.49 | NA |
| cold promptpad open p95 | NA | 185.49 | NA |
| cold promptpad-open p50 | NA | NA | NA |
| cold promptpad-open p95 | NA | NA | NA |
| bench returncode | 124 | 0 | -124.00 |

## Bench metrics newly available

Baseline run timed out; these were unavailable there and are now captured:

- warm_ctrl_g_to_editable_p95_ms: 5.05
- warm_open_roundtrip_p95_ms: 7.57
- warm_save_roundtrip_p95_ms: 1.05
- warm_agent_reflect_p95_ms: 0.60
- warm_type_p95_ms: 0.07
- cold_open_roundtrip_p95_ms: 231.43
