# PromptPad Optimization A/B Report

Generated from per-step benchmark summaries in docs/benchmarks/optimization-runs.

| Run | warm promptpad open p50 (ms) | warm promptpad open p95 (ms) | warm ok/err | warm cshim p50 (ms) | warm cshim ok/err | built-in bench timeout | built-in bench rc |
|---|---:|---:|---:|---:|---:|---|---:|
| 2026-02-17T03-43-25-baseline | 9.72 | 9.72 | 3/0 | NA | 0/3 | True | 124 |
| 2026-02-17T03-45-54-opt1-launch-agent | 210.79 | 210.79 | 3/0 | NA | 0/3 | True | 124 |
| 2026-02-17T03-47-13-opt2-focus-handshake | 37.35 | 37.35 | 3/0 | NA | 0/3 | True | 124 |
| 2026-02-17T03-48-29-opt3-first-paint | 82.11 | 82.11 | 3/0 | NA | 0/3 | True | 124 |
| 2026-02-17T03-49-47-opt4-styling-cache | 74.01 | 74.01 | 3/0 | NA | 0/3 | True | 124 |
| 2026-02-17T03-51-18-opt5-file-watcher | 36.29 | 36.29 | 3/0 | NA | 0/3 | True | 124 |
| 2026-02-17T03-53-56-opt6-editor-mode | 32.77 | 32.77 | 3/0 | NA | 0/3 | True | 124 |
| 2026-02-17T03-54-47-opt7-telemetry | 19.24 | 19.24 | 3/0 | NA | 0/3 | True | 124 |

## Notes

- Built-in promptpad bench command timed out in these runs (return code 124).
- Stepwise A/B comparisons were captured via custom command-latency samples and persisted per run.
