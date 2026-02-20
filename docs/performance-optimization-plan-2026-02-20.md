# TurboDraft Performance Optimization Plan
Date: 2026-02-20

## Current baseline (local short run)
Command:

```sh
.build/release/turbodraft bench run \
  --path "$(pwd)/bench/fixtures/dictation_flush_mode.md" \
  --warm 8 --cold 2 --warmup-discard 2 \
  --out /tmp/turbodraft-bench-current.json
```

Observed p95:

- `warm_cli_open_roundtrip_p95_ms`: `23.36`
- `warm_open_roundtrip_p95_ms`: `2.22`
- `warm_rpc_save_roundtrip_p95_ms`: `3.75`
- `warm_agent_reflect_p95_ms`: `5.61`
- `warm_textkit_insert_and_style_p95_ms`: `0.18`
- `cold_cli_open_roundtrip_p95_ms`: `255.01`

Status:

- `bench/editor/baseline.json`: pass
- `bench/baseline.json`: pass

## Bottleneck map
- Warm open tail is mostly CLI/editor-hook overhead, not server open work.
  - Evidence: `warm_cli_open` p95 (`23.36`) is much larger than `warm_open_roundtrip` p95 (`2.22`) and `warm_server_open` p95 (`0.54`).
- Save tail likely sits in session-side synchronous disk writes.
  - `EditorSession.autosave` does synchronous atomic write and recovery-store append on actor.
- Reflect tail likely comes from watcher -> apply pipeline and occasional scheduling jitter.
  - Current p95 is low but still much higher than median (`1.68` vs `5.61`).
- Text styling microbench is already strong (`0.18` p95), so this is not the first optimization target.

## Targets (next optimization cycle)
- `warm_cli_open_roundtrip_p95_ms` <= `15`
- `warm_open_roundtrip_p95_ms` <= `2`
- `warm_rpc_save_roundtrip_p95_ms` <= `2.5`
- `warm_agent_reflect_p95_ms` <= `3.5`
- Keep `warm_textkit_insert_and_style_p95_ms` <= `0.25`
- No regression in correctness tests or conflict handling

## Execution plan

### Phase 1 (high ROI, low risk)
1. Fix benchmark/path reliability issues.
   - Ensure all bench scripts pass absolute fixture paths to avoid `/bench/...` resolution errors when app cwd differs.
2. Reduce external editor invocation overhead.
   - Profile `scripts/turbodraft-editor` and favor `turbodraft-open` on hot path.
   - Remove avoidable shell/lookup work from each invocation.
3. Trim duplicate activation/focus work on open path.
   - Audit `EditorWindowController.openPath` and `EditorViewController.focusEditor` for redundant activation calls and retries.

### Phase 2 (medium effort)
1. Decouple recovery writes from autosave critical path.
   - Move `RecoveryStore.appendSnapshot` off synchronous autosave path (queue/batch strategy).
   - Keep crash safety by preserving atomic file write ordering.
2. Reduce unnecessary disk reads on watcher events.
   - Add cheap pre-check (`mtime`/size) before full file read+hash.
   - Keep atomic-replace compatibility.
3. Tighten save/reflect telemetry.
   - Split timings into parse/apply/io sub-phases so regressions point to exact stage.

### Phase 3 (deeper experiments behind flag)
1. Incremental fence-aware styling strategy.
   - Replace current “restyle to EOF on fence delimiter change” with bounded invalidation model.
2. Text engine/path experiment refresh.
   - Re-run `NSTextView` vs optional paths only after Phases 1–2 stabilize.

## Validation and rollout
1. Run functional safety net:
   - `swift test`
2. Run editor benchmarks:
   - `python3 scripts/bench_editor_suite.py --path bench/fixtures/dictation_flush_mode.md --warm 50 --cold 8`
3. Run startup trace benchmark:
   - `python3 scripts/bench_editor_startup_trace.py --cold 10 --warm 40 --min-valid-rate 0.98`
4. Compare before/after statistically:
   - `python3 scripts/bench_ab_compare.py --a <before.json> --b <after.json> --threshold-pct 5`
5. Gate merge on:
   - Baseline check pass
   - No significant regressions on existing metrics
   - Target metric movement in planned direction

## Risks and guardrails
- Keep session correctness first: no stale save acceptance and no conflict-banner regressions.
- Avoid changing both watcher semantics and autosave semantics in one PR.
- Keep one optimization theme per PR to simplify rollback and A/B validation.
