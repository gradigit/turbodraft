# PromptPad Launch/Lifecycle Benchmark Matrix

- Timestamp: 2026-02-17T04-17-33
- Fixture: /Users/aaaaa/Projects/promptpad/bench/fixtures/dictation_flush_mode.md
- warm_n: 12
- cold_n: 4

## Strict cold/warm comparison (`promptpad open`)

| Scenario | warm p50 (ms) | warm p95 (ms) | cold p50 (ms) | cold p95 (ms) | warm ok/err | cold ok/err |
|---|---:|---:|---:|---:|---:|---:|
| No LaunchAgent | 14.66 | 31.19 | NA | NA | 12/0 | 0/4 |
| LaunchAgent resident | 16.88 | 49.28 | 48.96 | 49.58 | 12/0 | 4/0 |
| Lifecycle: stay-resident | 15.40 | 35.81 | NA | NA | 12/0 | 0/4 |
| Lifecycle: terminate-on-last-close | 16.10 | 33.93 | 40.62 | 41.26 | 12/0 | 4/0 |

## Built-in `promptpad bench run` status

| Scenario | rc | timeout | elapsed (ms) |
|---|---:|---|---:|
| No LaunchAgent | 0 | False | 3064.37 |
| LaunchAgent resident | 0 | False | 615.23 |
| Lifecycle: stay-resident | 0 | False | 592.51 |
| Lifecycle: terminate-on-last-close (warm-only) | 0 | False | 1568.30 |

## Raw artifacts

- matrix.json: /Users/aaaaa/Projects/promptpad/docs/benchmarks/launch-matrix/2026-02-17T04-17-33/matrix.json
- logs/: /Users/aaaaa/Projects/promptpad/docs/benchmarks/launch-matrix/2026-02-17T04-17-33/logs

## Notes

- LaunchAgent benchmark uses isolated label from --launchagent-label.
- Lifecycle terminate-vs-stay uses dedicated PROMPTPAD_CONFIG paths under /tmp.
- Terminate-mode built-in bench is warm-only because cold bench spawns without terminate flag.
