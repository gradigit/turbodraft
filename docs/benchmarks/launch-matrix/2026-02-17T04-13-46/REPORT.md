# TurboDraft Launch/Lifecycle Benchmark Matrix

- Timestamp: 2026-02-17T04-13-46
- Fixture: /Users/aaaaa/Projects/turbodraft/bench/fixtures/dictation_flush_mode.md
- warm_n: 12
- cold_n: 4

## Strict cold/warm comparison (`turbodraft open`)

| Scenario | warm p50 (ms) | warm p95 (ms) | cold p50 (ms) | cold p95 (ms) | warm ok/err | cold ok/err |
|---|---:|---:|---:|---:|---:|---:|
| No LaunchAgent | 13.07 | 50.32 | NA | NA | 12/0 | 0/4 |
| LaunchAgent resident | 15.88 | 40.45 | 40.16 | 57.61 | 12/0 | 4/0 |
| Lifecycle: stay-resident | 14.31 | 30.86 | NA | NA | 12/0 | 0/4 |
| Lifecycle: terminate-on-last-close | 13.98 | 31.64 | 28.02 | 29.98 | 12/0 | 4/0 |

## Built-in `turbodraft bench run` status

| Scenario | rc | timeout | elapsed (ms) |
|---|---:|---|---:|
| No LaunchAgent | 0 | False | 1891.20 |
| LaunchAgent resident | 0 | False | 3229.04 |
| Lifecycle: stay-resident | 0 | False | 552.48 |
| Lifecycle: terminate-on-last-close (warm-only) | 0 | False | 3895.58 |

## Raw artifacts

- matrix.json: /Users/aaaaa/Projects/turbodraft/docs/benchmarks/launch-matrix/2026-02-17T04-13-46/matrix.json
- logs/: /Users/aaaaa/Projects/turbodraft/docs/benchmarks/launch-matrix/2026-02-17T04-13-46/logs

## Notes

- LaunchAgent benchmark uses isolated label from --launchagent-label.
- Lifecycle terminate-vs-stay uses dedicated TURBODRAFT_CONFIG paths under /tmp.
- Terminate-mode built-in bench is warm-only because cold bench spawns without terminate flag.
