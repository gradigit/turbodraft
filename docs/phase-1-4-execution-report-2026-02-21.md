# TurboDraft Phase 1–4 Execution Report

**Date:** 2026-02-21  
**Scope requested:** complete through Phase 4, defer Phase 5–6

## Summary

Completed implementation, self-review, and test pass for the pending security/correctness/robustness items targeted for Phase 1–4.

## Completed in this pass

### Phase 1 — Critical security/correctness

- **SEC-1** (`Sources/TurboDraftOpen/main.c`)  
  Replaced shell-based `system()` focus restore path with validated bundle ID + `posix_spawnp("osascript", ...)`.
- **SEC-2** (`Sources/TurboDraftOpen/main.c`)  
  Replaced raw `environ` forwarding with filtered spawn environment allowlist.
- **SEC-3** (`Sources/TurboDraftTransport/UnixDomainSocket.swift`)  
  Changed `getpeereid()` behavior from fail-open to fail-closed.
- **BUG-1** (`Sources/TurboDraftApp/EditorViewController.swift`, `EditorWindowController.swift`)  
  Fixed stale editor mode propagation by making mode mutable in VC and wiring window updates.
- **BUG-2** (`Sources/TurboDraftApp/AppDelegate.swift`, protocol + clients)  
  Added `session.close` RPC, session touch tracking, orphan sweep task, and cleanup-on-window-close/session wait.

### Phase 2 — Protocol hardening

- Added protocol version constant + message fields (`TurboDraftProtocolVersion.current`, `protocolVersion` in hello/open).
- Server now enforces protocol version on `session.open` and validates mismatch in `hello` when provided.
- C and Swift clients now send protocol version during open/hello flows.

### Phase 3 — Robustness/performance

- **ARCH-2** (`AppDelegate`)  
  Replaced silent config writes (`try?`) with sanitized write helper + `os.Logger` errors.
- **SEC-4** (`AppDelegate`)  
  Added explicit secure socket directory creation path (`0700` creation + set).
- **SEC-5** (`TurboDraftConfig`)  
  Added command sanitization policy for agent command (allowlisted/normalized and backend-aligned).
- **PERF-1** (`MarkdownHighlighter`)  
  Removed per-line substring allocation in fence-state prefix detection; switched to regex enumeration over prefix range.
- **PERF-2** (`EditorStyler`)  
  Removed substring-copy hash path in style cache key; now hashes UTF-16 chunks in-place.

### Phase 4 — Validation + regression guards

Added tests:
- `Tests/TurboDraftConfigTests/TurboDraftConfigTests.swift`
  - unknown command sanitization
  - backend/command alignment sanitization
- `Tests/TurboDraftMarkdownTests/MarkdownHighlighterTests.swift`
  - range-inside-fence state correctness
  - post-fence non-code state correctness
- `Tests/TurboDraftProtocolTests/TurboDraftMessagesTests.swift`
  - protocol default fields
  - session close message round-trip

## Commands run

- `swift test` (multiple runs, final pass green)
- `scripts/install` (run after code changes; final run successful, LaunchAgent restarted)

## Current test status

- **89 tests passed, 0 failed**.

## Fixes made during self-review

- Corrected close-RPC behavior in both C and Swift clients so close hint is only attempted after `session.wait` resolves to `userClosed` (not on timeout).

## Deferred (Phase 5–6 TODO)

### Phase 5 (deferred)
- P2 simplification/dead-code cleanup batch from production review (e.g., dead adapters/theme pruning/general LOC reduction).

### Phase 6 (deferred)
- P3 test coverage expansion and deeper verification work (RecoveryStore/file I/O coverage, app-level testability, broader perf/regression campaign).

