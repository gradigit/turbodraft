# TurboDraft Performance Review — Post Phase 1–4 Changes

**Date:** 2026-02-21  
**Goal:** Detect performance improvements/regressions introduced by recent Phase 1–4 changes.

## Scope reviewed

### Static code review (changed files)
- `Sources/TurboDraftMarkdown/MarkdownHighlighter.swift`
- `Sources/TurboDraftApp/EditorStyler.swift`
- `Sources/TurboDraftApp/AppDelegate.swift`
- `Sources/TurboDraftCLI/main.swift`
- `Sources/TurboDraftOpen/main.c`
- `Sources/TurboDraftTransport/UnixDomainSocket.swift`
- `Sources/TurboDraftProtocol/*`

### Runtime A/B benchmarking methodology
Compared current HEAD vs pre-change commit `bd06f08` using the same machine and comparable settings.

Bench command shape:
- `turbodraft-bench bench run --path <fixture> --warm N --cold N --warmup-discard N`

Fixtures used for comparison:
- `bench/fixtures/large_prompt.md`
- `bench/fixtures/xlarge_prompt.md`

## Executive summary

- **No material regressions detected** on user-critical latency metrics.
- **Clear improvement** in text styling throughput from the markdown/highlighter changes.
- Minor increases in some open-path p95 metrics exist, but they are **tiny in absolute terms** (roughly +0.08ms to +0.12ms on warm open roundtrip p95).
- Current results still pass `bench/editor/baseline.json` checks.

## Measured A/B results

## 1) `large_prompt.md` (paired run)

| Metric | Pre-change | Current | Delta |
|---|---:|---:|---:|
| warm_cli_open_roundtrip_p95_ms | 11.454 | 11.268 | -1.6% |
| warm_open_roundtrip_p95_ms | 0.696 | 0.777 | +11.7% |
| warm_server_open_p95_ms | 0.059 | 0.073 | +24.0% |
| warm_textkit_insert_and_style_p95_ms | 0.287 | 0.122 | **-57.4%** |
| warm_rpc_save_roundtrip_p95_ms | 9.412 | 9.090 | -3.4% |
| warm_server_save_p95_ms | 8.945 | 8.615 | -3.7% |
| warm_agent_reflect_p95_ms | 2.167 | 0.701 | -67.7% |
| cold_cli_open_roundtrip_p95_ms | 234.971 | 212.457 | -9.6% |

Notes:
- Open-path p95 increase is measurable but very small in absolute time.
- Styling throughput improvement is large and consistent.

## 2) `xlarge_prompt.md` (stress case)

| Metric | Pre-change | Current | Delta |
|---|---:|---:|---:|
| warm_cli_open_roundtrip_p95_ms | 12.987 | 13.147 | +1.2% |
| warm_open_roundtrip_p95_ms | 2.333 | 2.452 | +5.1% |
| warm_server_open_p95_ms | 0.103 | 0.105 | +2.3% |
| warm_textkit_insert_and_style_p95_ms | 1.764 | 0.838 | **-52.5%** |
| warm_rpc_save_roundtrip_p95_ms | 11.040 | 11.075 | +0.3% |
| warm_server_save_p95_ms | 9.784 | 9.923 | +1.4% |
| warm_agent_reflect_p95_ms | 2.156 | 2.132 | -1.1% |
| cold_cli_open_roundtrip_p95_ms | 224.118 | 220.185 | -1.8% |

Notes:
- Save and reflect remain effectively flat.
- Styling win remains strong even under larger file size.

## Static analysis findings

### Improvements introduced

1. **Reduced allocation overhead in styling/highlighting path**
   - `MarkdownHighlighter.computeFenceState` now avoids per-line substring churn.
   - `EditorStyler.cacheKey` now hashes UTF-16 in chunks instead of creating full substring copies.
   - This matches measured large/xlarge styling latency improvements.

2. **Session lifecycle cleanup stabilizes long-lived memory behavior**
   - New session close RPC + orphan sweep means fewer stale sessions over long agent uptime.
   - This is more of a long-horizon stability win than an immediate micro-latency win.

### Potential micro-regression vectors (not currently material)

1. **Slight warm open p95 increase**
   - Likely from additional per-request logic (`touchSession`, protocol checks, request-path bookkeeping).
   - Current increase is sub-millisecond and not user-visible in practice.

2. **Fence-state scan remains O(prefix length)**
   - Despite lower allocation overhead, fence-state computation still scales with prefix length.
   - Could matter at very large document sizes.

## Important non-performance issue discovered during perf validation

- Socket directory hardening currently attempts permission-setting on the socket parent directory unconditionally.
- Using a socket path under protected/shared dirs (for example, `/tmp`) can fail startup due permission errors.
- This is correctness/robustness, not throughput, but it blocked one benchmark setup and should be handled safely.

## Recommendations (priority order)

1. **P1: Keep current styling changes (confirmed win).**
2. **P1: Add incremental fence-state caching** to avoid repeated prefix scans on very large docs.
3. **P2: Reduce request-path bookkeeping overhead** only if future benchmarks show open-path drift (currently tiny).
4. **P1 correctness:** make socket-dir hardening tolerant of shared system dirs (do not fail startup when chmod/chown is not applicable).

## Verdict

From a performance perspective, the Phase 1–4 code changes are net-positive:
- **Major win:** text styling path
- **No material regressions:** open/save/reflect remain within expected bands
- **Baseline checks:** pass

