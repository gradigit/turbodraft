# Context Handoff — 2026-02-20 (Session 2)

Session summary for context continuity after clearing.

## First Steps (Read in Order)

1. Read CLAUDE.md — project conventions, build/install rule, architecture, gotchas
2. Read this file's session summary and next steps
3. Read `docs/production-readiness-review-2026-02-20.md` — full production readiness report with P0-P3 findings

After reading these files, you'll have full context to continue.

## Session Summary

### What Was Done

**Implemented deferred work from previous session + production readiness review.**

1. **Image passthrough: @refs at top** (commit cfd2b92) — Changed `attachedImages` from `[URL]` array to `[String: URL]` dictionary with 8-char UUID keys. Placeholders are now `[image-a3f2b1c4]` instead of `[image 1]`, making them stable across undo/redo. On close, regex scans for surviving placeholders, prepends `@/path/to/image.png` references at the top of the document so Claude reads images first, and cleans up temp files for undone/deleted images.

2. **ProcessHelpers refactor** (commit b53055b) — Extracted `setCloExec`, `setNonBlocking`, `writeAll` from 3 agent adapters into shared `Sources/TurboDraftAgent/ProcessHelpers.swift`. Removed ~80 lines of duplication.

3. **Image size limits TODO** — Created `todos/002-pending-p2-image-size-limits.md` for refusing oversized images (>20MB / >8000px) with user-facing error.

4. **Production readiness review** (commit a0404c4) — 4-agent parallel review (performance, security, architecture, simplicity) of the full 9,545-line codebase. Report saved to `docs/production-readiness-review-2026-02-20.md`.

### Current State
- All 77 tests pass on main
- Last commit: a0404c4 (3 commits ahead of origin/main, not pushed)
- LaunchAgent running latest binary
- Untracked files: `docs/benchmarks/editor/`, `docs/markdown-reference.txt`, `docs/theme-preview.html`, `research-image-passthrough-2026-02-20.md` (reference artifacts from previous sessions)

### What's Next — P0 Fixes from Production Review

These 5 items were identified as fix-before-shipping:

| # | Issue | File | Effort |
|---|-------|------|--------|
| **SEC-1** | Command injection via `system()` — `TURBODRAFT_TERMINAL_BUNDLE_ID` unsanitized | `main.c:635` | Low — replace `system()` with `posix_spawn` |
| **SEC-2** | Raw `environ` leaked to child via `posix_spawn` | `main.c:292,318` | Medium — filter env |
| **SEC-3** | `getpeereid()` fail-open — connections accepted without auth on failure | `UnixDomainSocket.swift:160` | 1-line fix |
| **BUG-1** | Stale `editorMode` in EditorViewController after config change | `EditorViewController.swift:454` | Low — propagate mode change |
| **BUG-2** | `sessionsById` memory leak — no session GC/close RPC | `AppDelegate.swift:497` | Medium — add periodic sweep |

### P1 Items (Fix Soon)

| # | Issue | Detail |
|---|-------|--------|
| **PERF-1** | O(n) fence-state prefix scan per keystroke | Fine for <5KB, 5-10ms at 100KB |
| **PERF-2** | O(n) cache key hashing via substring copy | Combined with PERF-1, can exceed 16ms at 100KB |
| **SEC-4** | Socket dir permissions briefly 0755 after creation | Use explicit `mkdir` mode |
| **SEC-5** | Config `agent.command` accepts arbitrary binaries | Add validation |
| **ARCH-1** | No protocol version enforcement | Implement version negotiation |
| **ARCH-2** | Config write failures silently swallowed (12 `try?` calls) | Add `os.Logger` on failure |

### P2 — Dead Code (~660 LOC removable)

See full list in `docs/production-readiness-review-2026-02-20.md` section P2.

Key items: `CodexCLIAgentAdapter.swift` (255 LOC dead code, never instantiated), `#if TURBODRAFT_USE_CODEEDIT_TEXTVIEW` (~80 LOC spike), vestigial `EditorTheme.swift`, 22→5 built-in themes.

### Failed Approaches
- Sequential `[image N]` placeholders — indices shift on undo/redo, corrupting references
- Clipboard-based image passthrough — hijacks user's clipboard, unreliable
- Appending @refs at bottom of document — Claude may not read images before prompt text

### Key Context
- User runs fish shell and Ghostty terminal — use OSC-8 hyperlinks with `tput` styling
- User has LaunchAgent installed — always run `scripts/install` after code changes
- Image placeholders use `[image-XXXX]` format (8-char hex UUID), NOT `[image N]`
- @file references are prepended at top of document on close, not appended at bottom
- `ProcessHelpers.swift` contains shared POSIX helpers — don't re-add to adapter files

## Reference Files

| File | Purpose |
|------|---------|
| `CLAUDE.md` | Project instructions for Claude Code |
| `docs/production-readiness-review-2026-02-20.md` | Full production readiness report (P0-P3) |
| `todos/002-pending-p2-image-size-limits.md` | Image size limit TODO |
| `Sources/TurboDraftApp/EditorViewController.swift` | Text editing, images, autosave, styling, agent |
| `Sources/TurboDraftAgent/ProcessHelpers.swift` | Shared setCloExec/setNonBlocking/writeAll |
| `Sources/TurboDraftAgent/CodexPromptEngineerAdapter.swift` | Primary agent adapter |
| `Sources/TurboDraftApp/AppDelegate.swift` | App lifecycle, socket server, RPC dispatch |
| `Sources/TurboDraftTransport/UnixDomainSocket.swift` | Socket security (getpeereid, chmod) |
| `Sources/TurboDraftOpen/main.c` | C CLI — has SEC-1 and SEC-2 issues |
