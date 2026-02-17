# HANDOFF — PromptPad

## Branch and commit chain
- Branch: `main`
- Current HEAD: `8d51c6b`
- Prior commit sequence (unchanged this session):
  1. `63d9020` chore: bootstrap repository and Swift package
  2. `47b24ae` feat(core): add protocol, transport, core session, config, and cli open path
  3. `3559c79` feat(app): add native AppKit editor with markdown behavior, autosave, and window/session flow
  4. `8e96939` feat(agent): add codex prompt-engineering adapters and guardrails
  5. `6b142c6` test: add unit and integration coverage
  6. `e80fa7c` perf(bench): add benchmark scripts, fixtures, baselines, and CI workflows
  7. `20ee4b9` docs: add benchmark methodology, research notes, and planning artifacts
  8. `8d51c6b` docs: refresh HANDOFF for fresh Claude Code continuation

## This session's work
- Full codebase evaluation audit (no code changes — read-only analysis)
- Produced `docs/EVALUATION_REPORT.md` with 46 findings across 4 severity levels

## Current repo state
- Untracked:
  - `HANDOFF.md` (this file, pending commit)
  - `docs/EVALUATION_REPORT.md` (new — codebase audit report)
  - `tmp/` (local benchmark artifacts; intentionally not committed)
- No modified tracked files.

## Verified status
- `swift build -c release`: pass
- `swift test`: pass (58 tests, 0 failures)

## Codebase evaluation summary (docs/EVALUATION_REPORT.md)

### Critical (5)
1. `applicationWillTerminate` async Task never completes — last edits lost on quit
2. `application(_:openFiles:)` replies success before async open finishes
3. `waitUntilClosed` continuation race — registered too late, permanent hang
4. Data race on `running` Bool in `UnixDomainSocketServer`
5. `wait_for_record()` json.loads without try/except corrupts JSONL offset

### High (15)
6-20: Sync I/O on actor, double-close fd, static lock contention, oversized-file error, thread pool blocking, continuation leak, retain cycle, partial state on throw, silent harness crash, FD exhaustion, zombie processes, timeout bypass, focus spam, concurrent agent guard, empty JSONL inflation

### Medium (14)
21-34: Missing optimistic concurrency, preamble loading in release builds, duplicate RPC IDs, thread safety gaps, overlapping highlights, TOCTOU races, orphan sessions, no protocol version enforcement, fragile CI sleeps, no subprocess timeouts, silent metric skips, XML injection, coercion duplication, hardcoded delays

### Low (12)
35-46: Cache performance, type safety, annotations, regex crash risk, menu state, race edge cases, gitignore gaps, dependency pinning, dead targets, accidental retention, ignored return values, double encoding

## Suggested next actions (priority order)
1. **Fix the 5 critical issues** — data loss on quit, openFiles reply, waitUntilClosed race, data race on Bool, JSONL parse corruption
2. **Harden E2E benchmark** — guaranteed report emission, early abort on consecutive errors, harness liveness checks, progress output (issues #5, #14, #20, #29)
3. **Fix high-severity Swift concurrency issues** — actor I/O blocking, continuation leaks, retain cycles (issues #6, #10, #11, #12)
4. **Add test coverage** — AppDelegate RPC dispatch, session reuse, timeout behavior, concurrent clients

## Key files for critical fixes
- Sources/PromptPadApp/AppDelegate.swift (issues #1, #2)
- Sources/PromptPadCore/EditorSession.swift (issues #3, #11, #13)
- Sources/PromptPadTransport/UnixDomainSocket.swift (issue #4)
- scripts/bench_editor_e2e_ux.py (issues #5, #14, #20)
- scripts/bench_editor_startup_trace.py (issue #5)

## Benchmark status (unchanged from prior session)

### Startup-trace benchmark (stable — primary latency gate)
- warm `ctrlGToPromptPadActiveMs` p95: 43.643 ms
- warm `ctrlGToEditorCommandReturnMs` p95: 51.428 ms
- warm `phasePromptPadReadyMs` p95: 9.864 ms

### E2E UX benchmark (flaky — needs hardening)
- Intermittent zero-valid runs due to AppleScript automation fragility
- Root cause: PromptPad process not found as frontmost in System Events
