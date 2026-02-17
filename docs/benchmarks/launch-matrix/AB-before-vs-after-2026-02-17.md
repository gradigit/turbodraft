# PromptPad A/B: Before vs After (all recent changes)

- Before: docs/benchmarks/launch-matrix/2026-02-17T04-17-33/matrix.json
- After: docs/benchmarks/launch-matrix/2026-02-17T04-24-42/matrix.json

## `promptpad open` cold/warm command latency

| Scenario | warm p50 before | warm p50 after | delta | cold p50 before | cold p50 after | delta |
|---|---:|---:|---:|---:|---:|---:|
| No LaunchAgent | 14.66 | 16.47 | +1.81 | NA | 158.80 | NA |
| LaunchAgent resident | 16.88 | 17.88 | +1.01 | 48.96 | 59.04 | +10.08 |
| Lifecycle stay-resident | 15.40 | 16.71 | +1.32 | NA | 149.12 | NA |
| Lifecycle terminate-on-last-close | 16.10 | 15.07 | -1.03 | 40.62 | 46.47 | +5.86 |

## Built-in `promptpad bench run` duration

| Scenario | before elapsed ms | after elapsed ms | delta | before rc | after rc |
|---|---:|---:|---:|---:|---:|
| No LaunchAgent | 3064.37 | 1888.55 | -1175.82 | 0 | 0 |
| LaunchAgent resident | 615.23 | 600.46 | -14.77 | 0 | 0 |
| Lifecycle stay-resident | 592.51 | 1950.93 | +1358.42 | 0 | 0 |
| Lifecycle terminate-on-last-close | 1568.30 | 345.35 | -1222.95 | 0 | 0 |

## Reliability changes

- No LaunchAgent: cold success 0/4 -> 4/4
- LaunchAgent resident: cold success 4/4 -> 4/4
- Lifecycle stay-resident: cold success 0/4 -> 4/4
- Lifecycle terminate-on-last-close: cold success 4/4 -> 4/4
