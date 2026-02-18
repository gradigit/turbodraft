# TurboDraft Launch/Lifecycle Benchmark Matrix

- Timestamp: 2026-02-17T04-24-42
- Fixture: /Users/aaaaa/Projects/turbodraft/bench/fixtures/dictation_flush_mode.md
- warm_n: 12
- cold_n: 4

## Strict cold/warm comparison (`turbodraft open`)

| Scenario | warm p50 (ms) | warm p95 (ms) | cold p50 (ms) | cold p95 (ms) | warm ok/err | cold ok/err |
|---|---:|---:|---:|---:|---:|---:|
| No LaunchAgent | 16.47 | 44.55 | 158.80 | 161.56 | 12/0 | 4/0 |
| LaunchAgent resident | 17.88 | 39.83 | 59.04 | 60.00 | 12/0 | 4/0 |
| Lifecycle: stay-resident | 16.71 | 46.42 | 149.12 | 160.97 | 12/0 | 4/0 |
| Lifecycle: terminate-on-last-close | 15.07 | 30.78 | 46.47 | 53.24 | 12/0 | 4/0 |

## Built-in `turbodraft bench run` status

| Scenario | rc | timeout | elapsed (ms) |
|---|---:|---|---:|
| No LaunchAgent | 0 | False | 1888.55 |
| LaunchAgent resident | 0 | False | 600.46 |
| Lifecycle: stay-resident | 0 | False | 1950.93 |
| Lifecycle: terminate-on-last-close (warm-only) | 0 | False | 345.35 |

## Raw artifacts

- matrix.json: /Users/aaaaa/Projects/turbodraft/docs/benchmarks/launch-matrix/2026-02-17T04-24-42/matrix.json
- logs/: /Users/aaaaa/Projects/turbodraft/docs/benchmarks/launch-matrix/2026-02-17T04-24-42/logs

## Notes

- LaunchAgent benchmark uses isolated label from --launchagent-label.
- Lifecycle terminate-vs-stay uses dedicated TURBODRAFT_CONFIG paths under /tmp.
- Terminate-mode built-in bench is warm-only because cold bench spawns without terminate flag.
