# TurboDraft Production Readiness Review

**Date:** 2026-02-20
**Reviewed by:** 4 parallel agents (Performance, Security, Architecture, Simplicity)

## Verdict: Nearly production-ready. Fix the 3 security issues and 2 correctness bugs first.

9,545 lines of source, 77 tests passing. The architecture is solid — clean module graph, actor-based concurrency, atomic writes, crash recovery. No show-stoppers, but several concrete issues across security, correctness, and robustness.

---

## P0 — Fix Before Shipping

### Security

| # | Issue | File | Fix effort |
|---|-------|------|------------|
| **SEC-1** | **Command injection** via `system()` in `restore_terminal_focus()`. `TURBODRAFT_TERMINAL_BUNDLE_ID` is unsanitized → shell injection. | `main.c:635` | Low — replace `system()` with `posix_spawn` |
| **SEC-2** | **C CLI passes raw `environ`** to `posix_spawn`. Leaks caller's API keys/tokens to `turbodraft-app`. | `main.c:292,318` | Medium — filter env |
| **SEC-3** | **`getpeereid()` fail-open**. If the call fails, connections are silently accepted without auth. | `UnixDomainSocket.swift:160` | 1-line fix |

### Correctness

| # | Issue | File | Fix effort |
|---|-------|------|------------|
| **BUG-1** | **Stale `editorMode`** in EditorViewController. Switching Reliable↔UltraFast only updates the window controller's config copy, not the VC's. Existing editors use wrong styling thresholds. | `EditorViewController.swift:454` | Low — propagate mode change to VC |
| **BUG-2** | **`sessionsById` memory leak.** No `sessionClose` RPC or GC sweep. Crashed CLI clients leave orphaned entries indefinitely. Over weeks of LaunchAgent uptime, this grows unbounded. | `AppDelegate.swift:497` (TODO) | Medium — add periodic sweep |

---

## P1 — Fix Soon (Robustness)

| # | Issue | Source | Detail |
|---|-------|--------|--------|
| **PERF-1** | O(n) fence-state prefix scan per keystroke in `computeFenceState` | `MarkdownHighlighter.swift:146` | Fine for <5KB prompts, but 5-10ms at 100KB. Cache incrementally. |
| **PERF-2** | O(n) cache key hashing via full substring copy | `EditorStyler.swift:219` | Combined with PERF-1, can exceed 16ms frame budget at 100KB. |
| **SEC-4** | Socket directory permissions applied after creation (briefly 0755) | `AppDelegate.swift:67` | Use explicit `mkdir` mode |
| **SEC-5** | Config `agent.command` accepts arbitrary binaries without allowlist | `TurboDraftConfig.swift:100` | Medium — add validation |
| **ARCH-1** | No protocol version enforcement — old client + new server silently mismatch | `AppDelegate.swift:349` (TODO) | Implement version negotiation |
| **ARCH-2** | Config write failures silently swallowed (12 `try?` calls) | `AppDelegate.swift:857+` | Add `os.Logger` on failure |

---

## P2 — Cleanup (Dead Code + Simplification)

| # | Item | LOC saved |
|---|------|-----------|
| `CodexCLIAgentAdapter.swift` — never instantiated, pure dead code | **255** |
| `#if TURBODRAFT_USE_CODEEDIT_TEXTVIEW` — spike code, never compiles | **~80** |
| `EditorTheme.swift` — vestigial, inline 6 colors into `defaultTheme` | **58** |
| Extract shared `spawnAndCapture` into `ProcessHelpers.swift` | **~80** (net) |
| Unify `CodexPromptEngineerError` + `CodexAppServerPromptEngineerError` into one `AgentError` | **~20** |
| Remove dead functions: `HistoryStore.all()`, `SessionOpenParams.requestId`, `PromptEngineerPrompts.systemPreamble`, `CLI.waitViaSocket` | **~13** |
| Trim built-in themes from 22 to ~5, ship rest as JSON files | **~200** |
| **Total potential reduction** | **~660 LOC (~7%)** |

---

## P3 — Test Coverage Gaps

| Module | Gap |
|--------|-----|
| `RecoveryStore` | Zero tests for crash recovery — the most critical data-loss prevention feature |
| `FileIO.writeTextAtomically` | Atomic write + permission preservation untested |
| `TurboDraftApp` | 1,100 lines, zero tests (needs dependency injection to become testable) |
| Overall ratio: 1,000 test lines / 9,500 source = **10.5%** (low for production; 25-40% is typical) |

---

## What's Already Good

- **Clean module graph** — acyclic, well-layered, no circular deps
- **Actor/MainActor discipline** — no data races on session state or UI
- **Atomic file writes** + crash recovery via `RecoveryStore`
- **Socket security** — chmod 0600, `getpeereid()` same-UID check, `FD_CLOEXEC`
- **Window pooling** — eliminates cold start for Ctrl+G
- **Performance instrumentation** — telemetry, benchmarks with Mann-Whitney regression detection
- **Graceful shutdown** with timeouts preventing quit hangs
- **Well-documented gotchas** in CLAUDE.md

---

## Detailed Findings by Review Domain

### Performance (agent: performance-oracle)

Full report highlights:
- `MarkdownHighlighter.computeFenceState` scans from line 0 to cursor on every restyle — O(n) per keystroke
- `EditorStyler.cacheKey` copies and hashes the entire styling range substring
- `_typingLatencies` uses `Array.removeFirst()` (O(n)) — should be ring buffer
- `RecoveryStore.readStoredSnapshots` does synchronous `writeQueue.sync {}` drain on session open path
- `ISO8601DateFormatter` allocated on every telemetry record — should be static
- `HistoryStore` retains full document copies (64 * 2MB worst case = 128MB)
- Document size scaling: ~1ms at 1KB, ~4ms at 10KB, ~28ms at 100KB per keystroke

### Security (agent: security-sentinel)

2 HIGH, 5 MEDIUM, 5 LOW findings.

**HIGH-1:** Command injection via `system()` in `restore_terminal_focus()` (`main.c:635`). `TURBODRAFT_TERMINAL_BUNDLE_ID` env var is used unsanitized in a shell command.

**HIGH-2:** C CLI uses raw `environ` for `posix_spawn` (`main.c:292,318`). Leaks full environment including secrets to child processes. Contradicts CLAUDE.md convention.

**MEDIUM-1:** TOCTOU race in socket stale-file cleanup (`UnixDomainSocket.swift:78-88`).
**MEDIUM-2:** Socket directory permissions applied after creation (`AppDelegate.swift:67-69`).
**MEDIUM-3:** `getpeereid()` fail-open (`UnixDomainSocket.swift:160-169`).
**MEDIUM-4:** No rate limiting or session enumeration protection on JSON-RPC.
**MEDIUM-5:** Config `agent.command` allows arbitrary command execution.

Positive: socket chmod 0600, `FD_CLOEXEC`, agent output size limits, process timeouts with SIGTERM grace + SIGKILL, temp file cleanup.

### Architecture (agent: architecture-strategist)

Clean module graph (acyclic), good actor/MainActor discipline, all `@unchecked Sendable` uses verified correct.

Key issues:
- Missing `sessionClose` RPC — orphaned sessions leak memory over LaunchAgent lifetime
- Stale `editorMode` in EditorViewController — config value copy not propagated
- No protocol version enforcement
- Silent config write failures (12 `try?` calls)
- Minimal logging throughout (2 `NSLog` + 1 `os.Logger`)
- No RecoveryStore tests (complex pruning/dedup logic untested)
- Test-to-source ratio: 10.5%

Strengths: well-structured module boundaries, robust socket lifecycle, atomic file writes, crash recovery, graceful shutdown with timeouts, comprehensive benchmark infrastructure.

### Simplicity (agent: code-simplicity-reviewer)

~660 LOC removable (7% of codebase):
- `CodexCLIAgentAdapter.swift` — 255 lines of dead code (never instantiated)
- `#if TURBODRAFT_USE_CODEEDIT_TEXTVIEW` — ~80 lines of spike code that never compiles
- `EditorTheme.swift` — 58 lines, vestigial (inline into `defaultTheme`)
- 22 built-in themes (only 5 needed, rest can be JSON files)
- Duplicated `spawnAndCapture` across adapters (~80 lines extractable)
- 6 dead functions across various files
- 2 near-identical agent error enums unifiable into one
