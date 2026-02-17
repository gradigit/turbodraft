# PromptPad Launch/Lifecycle Benchmark Matrix

- Timestamp: 2026-02-17T04-11-07
- Fixture: /Users/aaaaa/Projects/promptpad/bench/fixtures/dictation_flush_mode.md
- warm_n: 12
- cold_n: 4

## Strict cold/warm comparison (`promptpad open`)

| Scenario | warm p50 (ms) | warm p95 (ms) | cold p50 (ms) | cold p95 (ms) | warm ok/err | cold ok/err |
|---|---:|---:|---:|---:|---:|---:|
| No LaunchAgent | 11.81 | 22.32 | 503.19 | 503.19 | 12/0 | 3/1 |
| LaunchAgent resident | 13.80 | 1384.28 | 63.50 | 71.88 | 12/0 | 4/0 |
| Lifecycle: stay-resident | 16.85 | 37.75 | NA | NA | 12/0 | 0/4 |
| Lifecycle: terminate-on-last-close | 15.54 | 41.40 | 47.15 | 49.80 | 12/0 | 4/0 |

## Built-in `promptpad bench run` status

| Scenario | rc | timeout | elapsed (ms) |
|---|---:|---|---:|
| No LaunchAgent | 1 | False | 519.15 |
| LaunchAgent resident | 0 | False | 594.42 |
| Lifecycle: stay-resident | 0 | False | 3873.91 |
| Lifecycle: terminate-on-last-close (warm-only) | 0 | False | 3060.35 |

## Raw artifacts

- matrix.json: /Users/aaaaa/Projects/promptpad/docs/benchmarks/launch-matrix/2026-02-17T04-11-07/matrix.json
- logs/: /Users/aaaaa/Projects/promptpad/docs/benchmarks/launch-matrix/2026-02-17T04-11-07/logs

## Notes

- LaunchAgent benchmark uses isolated label from --launchagent-label.
- Lifecycle terminate-vs-stay uses dedicated PROMPTPAD_CONFIG paths under /tmp.
- Terminate-mode built-in bench is warm-only because cold bench spawns without terminate flag.
