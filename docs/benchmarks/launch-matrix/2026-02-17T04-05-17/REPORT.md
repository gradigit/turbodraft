# PromptPad Launch/Lifecycle Benchmark Matrix

- Timestamp: 2026-02-17T04-05-17
- Fixture: /Users/aaaaa/Projects/promptpad/bench/fixtures/dictation_flush_mode.md
- warm_n: 12
- cold_n: 4

## Strict cold/warm comparison (promptpad open)

| Scenario | warm p50 (ms) | warm p95 (ms) | cold p50 (ms) | cold p95 (ms) | warm ok/err | cold ok/err |
|---|---:|---:|---:|---:|---:|---:|
| No LaunchAgent | 14.25 | 33.34 | NA | NA | 12/0 | 0/4 |
| LaunchAgent resident | 21.83 | 75.65 | 61.16 | 63.10 | 12/0 | 4/0 |
| Lifecycle: stay-resident | 16.59 | 45.68 | 680.76 | 680.76 | 12/0 | 2/2 |
| Lifecycle: terminate-on-last-close | 11.51 | 20.12 | 22.71 | 25.65 | 12/0 | 4/0 |

## Built-in bench run status

| Scenario | rc | timeout | elapsed (ms) |
|---|---:|---|---:|
| No LaunchAgent | 0 | False | 165387.59 |
| LaunchAgent resident | 0 | False | 862.40 |
| Lifecycle: stay-resident | 0 | False | 12060.30 |
| Lifecycle: terminate-on-last-close (warm-only) | 0 | False | 1700.05 |

## Notes

- LaunchAgent uses an isolated temporary label for this benchmark run.
- Lifecycle terminate-vs-stay cold tests are controlled with dedicated PROMPTPAD_CONFIG files and socket paths.
- Raw logs are in logs/*.bench.stdout.log and logs/*.bench.stderr.log.
