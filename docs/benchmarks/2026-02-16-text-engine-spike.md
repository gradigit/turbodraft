# Text Engine Spike: `NSTextView` vs `CodeEditTextView`
Date: 2026-02-16

## Goal
Run an A/B spike against the same PromptPad codebase to check whether swapping the editor surface to `CodeEditTextView` improves the latency metrics that matter for PromptPad.

## Command
```sh
scripts/bench_text_engine_spike.sh --warm 8 --cold 2
```

## Artifacts
`tmp/bench_text_engine_spike_20260216-223730`

- `tmp/bench_text_engine_spike_20260216-223730/nstextview/results.json`
- `tmp/bench_text_engine_spike_20260216-223730/codeedit_textview/results.json`

## Result Summary (lower is better)

| Metric | NSTextView | CodeEditTextView | Delta |
|---|---:|---:|---:|
| `warm_ctrl_g_to_editable_p95_ms` | 4.08 | 4.76 | +16.8% |
| `warm_open_roundtrip_p95_ms` | 1.25 | 5.29 | +322.0% |
| `warm_save_roundtrip_p95_ms` | 0.85 | 0.99 | +15.3% |
| `warm_agent_reflect_p95_ms` | 37.13 | 44.44 | +19.7% |
| `cold_open_roundtrip_p95_ms` | 124.83 | 129.25 | +3.5% |

## Interpretation
- For this app shape and current integration, `NSTextView` is faster on all measured metrics.
- The largest regression is warm open round-trip (`+322%`), which directly hurts the Ctrl+G edit path.
- Decision for now: keep `NSTextView` as default/perf path.

## Notes
- The CodeEdit integration remains behind compile flag `PROMPTPAD_USE_CODEEDIT_TEXTVIEW` for future experiments.
- This is an initial spike with short sample counts (`warm=8`, `cold=2`). Re-run with larger samples before making any final architectural changes.
