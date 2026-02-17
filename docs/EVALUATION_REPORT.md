# PromptPad Codebase Evaluation Report

Full audit across Swift sources, Python scripts, CI workflows, and architecture.

---

## CRITICAL (5 issues)

### 1. `applicationWillTerminate` async Task never completes — last edits lost on quit
Sources/PromptPadApp/AppDelegate.swift:120-131

`applicationWillTerminate` spawns a `Task { @MainActor in ... }` to flush autosaves and mark sessions closed. The process can exit before the async Task runs. Unsaved edits from the last keystroke are silently dropped on every app quit.

**Fix:** Run the flush synchronously, or block the main thread with a semaphore/RunLoop until I/O completes.

---

### 2. `application(_:openFiles:)` replies success before async open completes
Sources/PromptPadApp/AppDelegate.swift:100-118

`sender.reply(toOpenOrPrint: .success)` fires at line 117 before the `Task` at lines 102-115 finishes. If `wc.openPath` throws, the system is told the file opened successfully, the EditorWindowController leaks (never registered), and the user sees nothing.

**Fix:** Reply inside the Task's completion, or reply `.failure` on error.

---

### 3. Race in `waitUntilClosed` — continuation registered too late, hangs forever
Sources/PromptPadCore/EditorSession.swift:237-263

The inner `Task { await self.addWaiter(cont) }` inside `withCheckedContinuation` registers the continuation asynchronously. If `markClosed()` fires between the continuation starting and `addWaiter` executing, the continuation is never resumed — permanent hang.

**Fix:** Register the waiter synchronously within the actor-isolated context, or use `withCheckedContinuation` directly inside an actor method.

---

### 4. Data race on `running` Bool in `UnixDomainSocketServer`
Sources/PromptPadTransport/UnixDomainSocket.swift:196-215

`running` is a plain `var Bool` read from the accept-loop thread and written by `stop()` from another thread. No synchronization. Undefined behavior under Swift's memory model.

**Fix:** Use `Atomic<Bool>`, `os_unfair_lock`, or dispatch the flag through the queue.

---

### 5. `wait_for_record()` — `json.loads` without try/except corrupts offset on malformed JSONL
scripts/bench_editor_e2e_ux.py:193
scripts/bench_editor_startup_trace.py:118

If the harness emits partial JSON (crash mid-write), `json.loads` raises, the offset is never advanced, and subsequent calls re-read the same corrupt bytes until timeout — burning all remaining attempts.

**Fix:** Wrap `json.loads` in try/except, advance offset past the bad line.

---

## HIGH (15 issues)

### 6. Sync file I/O on EditorSession actor starves all continuations
Sources/PromptPadCore/EditorSession.swift:54

`open()`, `autosave()`, `applyExternalDiskChange()` all do synchronous file I/O while holding the actor's isolation. A slow disk (network volume, spinning) stalls every waiting continuation.

### 7. `DirectoryWatcher` double-close of file descriptor
Sources/PromptPadCore/DirectoryWatcher.swift:30-51

If `stop()` is called twice (explicitly + deinit), the cancel handler fires twice on the same fd. Closing a reused fd is a security bug.

### 8. `RecoveryStore` uses a static lock shared across all instances
Sources/PromptPadCore/RecoveryStore.swift:12-13

All `RecoveryStore` instances contend on one global `NSLock`, serializing unrelated file I/O unnecessarily. Should be per-instance.

### 9. `FileIO.readText` misclassifies oversized files as "not a file"
Sources/PromptPadCore/FileIO.swift:8-18

Files exceeding `maxBytes` throw `FileIOError.notAFile` instead of a dedicated `.fileTooLarge` case. Users see a confusing error.

### 10. `CodexCLIAgentAdapter.spawnAndCapture` blocks the cooperative thread pool
Sources/PromptPadAgent/CodexCLIAgentAdapter.swift:74-231

Blocking `poll()` loop (up to 30s) runs inside `async` context. Under load, this can deadlock Swift concurrency's bounded thread pool.

### 11. Weak self in timeout Task → continuation leak on dealloc
Sources/PromptPadCore/EditorSession.swift:213-222

If the session is deallocated before the timeout fires, `self?` is nil, `finishRevisionWaiter` is never called, and the `CheckedContinuation` is permanently leaked (caller hangs).

### 12. `EditorWindowController` observer captures self strongly — retain cycle
Sources/PromptPadApp/EditorWindowController.swift:47-62

Outer closure passed to `addObserver(forName:...)` captures `self` strongly. `[weak self]` is only in the inner Task. NotificationCenter retains the block → retain cycle until `deinit` fires (but deinit can't fire while retained).

### 13. `EditorSession.open` partial state on throw
Sources/PromptPadCore/EditorSession.swift:54-105

If `FileIO.readText` or `recoveryStore.loadSnapshots` throws mid-way, the session has a new `fileURL` but old `content`, `diskRevision`, `isDirty`. Inconsistent state.

### 14. Harness crash is completely silent — timeout is the only signal
scripts/bench_editor_e2e_ux.py:386-392
scripts/bench_editor_startup_trace.py:285-291

Harness stdout/stderr go to DEVNULL. If it crashes, the benchmark silently times out on every attempt. No `harness_proc.poll()` check in the loop.

### 15. `bench_codex_prompt_engineer.py` — unclosed file handles exhaust FDs
scripts/bench_codex_prompt_engineer.py:33,208,242,1521,1538

`open()` without context managers across 378+ iterations. macOS default is 256 FDs — crash likely in CI.

### 16. `bench_codex_prompt_engineer.py` — `app_proc` zombie (no `wait()` in finally)
scripts/bench_codex_prompt_engineer.py:1940-1950

`terminate()` without `wait()` → zombie process accumulation in CI.

### 17. `bench_codex_prompt_engineer.py` — `TimeoutExpired` bypasses retry loop
scripts/bench_codex_prompt_engineer.py:792-825

`subprocess.run(timeout=...)` raises `TimeoutExpired` which is not caught inside the retry loop. First slow run crashes the entire benchmark.

### 18. `focusEditor` fires 5+ redundant `makeFirstResponder` calls in 160ms
Sources/PromptPadApp/EditorViewController.swift:245-272

Combined with `windowDidBecomeKey`, `windowDidBecomeMain`, and `didBecomeActiveObserver`, this produces 8-15 responder chain walks per window open. Can steal focus from user clicks.

### 19. `runAgent` has no concurrent-run guard via menu shortcut
Sources/PromptPadApp/EditorViewController.swift:552-618

`agentButton.isEnabled = false` prevents button re-entry, but `runPromptEngineer()` from the menu bypasses this check. Two concurrent agent runs corrupt each other's output.

### 20. Empty JSONL lines inflate invalid-run count, prevent reaching target_valid
scripts/bench_editor_e2e_ux.py:189-196

Empty lines return `{}`, get counted as invalid attempts, degrading valid-run rate without explanation.

---

## MEDIUM (14 issues)

### 21. `sessionSave` ignores `baseRevision` and `force` — no optimistic concurrency
Sources/PromptPadApp/AppDelegate.swift:383-398

### 22. `#filePath` preamble loading fails in release/installed builds
Sources/PromptPadAgent/PromptEngineerPrompts.swift:18-46

### 23. Duplicate JSON-RPC request ID 3 in sendSessionSave/sendSessionWait
Sources/PromptPadCLI/main.swift:465-467

### 24. `ContentLengthFramer` not thread-safe but marked `@unchecked Sendable`
Sources/PromptPadTransport/ContentLengthFramer.swift

### 25. Overlapping highlights for `> # Heading` lines
Sources/PromptPadMarkdown/MarkdownHighlighter.swift:204-236

### 26. TOCTOU race in `appendLatencyRecord` file check/open
Sources/PromptPadApp/AppDelegate.swift:803-823

### 27. `sessionsById` entries orphaned when CLI dies without `sessionWait`
Architecture gap — no explicit `sessionClose` RPC, no GC sweep.

### 28. No protocol version enforcement in hello handshake
CLI ignores `protocolVersion` field; mismatched versions silently proceed.

### 29. Fixed 0.9s harness startup sleep — fragile on slow CI
scripts/bench_editor_e2e_ux.py:395

No readiness probe. Should poll for harness process or log file.

### 30. `bench_prompt_suite.py` / `bench_editor_suite.py` — `subprocess.run` with no timeout
scripts/bench_prompt_suite.py:15

Child script hang → parent hangs indefinitely. CI timeout is the only backstop.

### 31. `check_prompt_benchmark.py` — `None` metrics silently skip threshold check
scripts/check_prompt_benchmark.py:68-71

A benchmark where every run errors out appears to pass all thresholds.

### 32. Plist XML injection in `promptpad-launch-agent` if path contains `<>&`
scripts/promptpad-launch-agent:55-75

### 33. Spark reasoning-effort coercion duplicated in 3 places
AppDelegate, sanitized(), CodexPromptEngineerAdapter — maintenance hazard.

### 34. Hardcoded 180ms autosave delay in AppleScript doesn't match configurable debounce
scripts/bench_editor_e2e_ux.py:138

---

## LOW (12 issues)

### 35. `MarkdownStyler` cache eviction is O(n) via `Array.removeFirst`
### 36. `JSONRPCResponse` allows both `result` and `error` simultaneously
### 37. `BannerView` not annotated `@MainActor`
### 38. 14 `try!` regex compilations — crash-on-first-use risk
### 39. `agentEnabledMenuItem` reference orphaned after `installMenu()` rebuild
### 40. `waitUntilClosed(timeoutMs: 0)` on closed session can return false (race)
### 41. `tmp/` and `docs/benchmarks/` not in `.gitignore`
### 42. CodeEdit spike dependency uses `branch: "main"` — not reproducible
### 43. `PromptPadOpen` target declared in Package.swift but no source directory
### 44. `handleClient` doesn't retain `JSONRPCServerConnection` — works by accident
### 45. `FileIO.writeTextAtomically` ignores `createFile` return value
### 46. Double encode/decode on every RPC response via AnyEncodable round-trip

---

## Test Coverage Gaps

| Area | Status |
|---|---|
| Protocol codec, framing | Covered |
| UDS bind/connect | 2 tests |
| EditorSession open/autosave/wait | Partially covered |
| AppDelegate RPC dispatch | **Not tested** |
| Session reuse logic | **Not tested** |
| Timeout behavior (waitUntilClosed, waitUntilRevisionChange) | **Not tested** |
| Multiple concurrent clients | **Not tested** |
| `appQuit` during active session | **Not tested** |
| `--stdio` mode | **Not tested** |
| File deleted mid-session | **Not tested** |
| PromptPadOpen C launcher | **Zero tests** |
| RecoveryStore under contention | **Not tested** |

---

## Architecture Summary

| Category | Rating | Key Issue |
|---|---|---|
| Module boundaries | Good | Minor coupling: CommandResolver leaks Core into Agent |
| IPC design | Good | Gaps: no version enforcement, no `sessionClose`, orphan sessions |
| Session lifecycle | Good | Gaps: no explicit release, partial state on throw |
| Window/App lifecycle | Mixed | `applicationWillTerminate` async flush, focus retry spam |
| Config/persistence | Mixed | Preamble loading breaks in release, triplicated coercion logic |
| Test coverage | Sparse | AppDelegate dispatch, reuse, timeouts, stdio all untested |
| Benchmark scripts | Mixed | Silent failures, FD leaks, zombie processes, no timeouts |
| Documentation | Adequate | Missing: protocol spec, architecture doc |
