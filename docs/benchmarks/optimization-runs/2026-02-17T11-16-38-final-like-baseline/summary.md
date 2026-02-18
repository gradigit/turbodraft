# TurboDraft Optimization Benchmark: final-like-baseline

- Timestamp: 2026-02-17T11-16-38
- Fixture: /Users/aaaaa/Projects/turbodraft/bench/fixtures/dictation_flush_mode.md
- Bench command return code: 0

## Command latency (ms)

- warm `turbodraft open` p50: 18.64170800000009
- warm `turbodraft open` p95: 18.64170800000009
- warm `turbodraft-open` p50: 12.158957999999886
- warm `turbodraft-open` p95: 12.158957999999886
- cold `turbodraft open` p50: 185.48579199999992
- cold `turbodraft open` p95: 185.48579199999992
- cold `turbodraft-open` p50: None
- cold `turbodraft-open` p95: None

## turbodraft bench run metrics

- cold_open_roundtrip_p95_ms: 231.428666
- warm_agent_reflect_p95_ms: 0.601708
- warm_ctrl_g_to_editable_p95_ms: 5.051416
- warm_open_roundtrip_p95_ms: 7.573542
- warm_save_roundtrip_p95_ms: 1.047208
- warm_type_p95_ms: 0.072167

