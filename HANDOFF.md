# Context Handoff — 2026-02-19

Session summary for context continuity after clearing.

## First Steps (Read in Order)

1. Read CLAUDE.md — project conventions, build/install rule, architecture, gotchas
2. Read README.md — open-source README with install, usage, performance, architecture
3. Read this file's "Deferred Work" section — known issues not addressed this session

After reading these files, you'll have full context to continue.

## Session Summary

### What Was Done

**Fixed bugs and code quality issues from PRs #2, #4, #5, #6** (4 merged PRs from contributor `guzus`, +185/-34 LOC, zero tests)

Fixes implemented:

1. **Extracted `buildEnv` to `CommandResolver`** — deduplicated from two adapters, now a single `CommandResolver.buildEnv(prependingToPath:)` using `ProcessInfo.processInfo.environment` (thread-safe) instead of raw C `environ`
2. **Applied `buildEnv` to `CodexCLIAgentAdapter`** — was missing entirely, causing spawn failures under LaunchAgent
3. **Added warning when CLI adapter receives images** — `CodexCLIAgentAdapter` has no mechanism to forward images but silently accepted them
4. **Fixed repair turns re-sending images** — both `CodexPromptEngineerAdapter` and `CodexAppServerPromptEngineerAdapter` now pass `images: []` on repair
5. **Fixed session switch image bleed** — `applySessionInfo` now cleans up stale temp files and clears `attachedImages`
6. **Fixed temp file leak in deinit** — `EditorViewController.deinit` now removes orphaned image temp files
7. **Removed dead nvm alias resolution** — `~/.nvm/alias/default` contains alias strings (e.g. "22"), not directory names; the version-scan fallback already handles this
8. **Fixed fnm base directory** — now checks all 3 known locations (`~/.local/share/fnm`, `~/.fnm`, `~/Library/Application Support/fnm`)
9. **Cached `supplementalPaths`** — changed from computed `var` (filesystem I/O every call) to `static let`
10. **Fixed `saveTempImage` silent failure** — write errors now return `nil` instead of a URL to a nonexistent file
11. **Removed broken MCP disable flags from Python scripts** — `bench_codex_prompt_engineer.py` (4 occurrences) and `codex_app_server_poc.py`
12. **Added 9 new tests** — `CommandResolverTests` (8 tests for `resolveInPATH` + `buildEnv`) and `CodexAdapterTests.testAdapterIgnoresImagesGracefully`
13. **Updated CLAUDE.md** — test count 58→67, module count 8→10, added `CommandResolver.swift` to key files, added gotchas

### Current State
- All 67 tests pass on main
- Release build clean, LaunchAgent restarted via `scripts/install`
- Changes are uncommitted (ready to commit)

### What's Next (Deferred Work)

| Issue | Reason deferred |
|-------|----------------|
| Extract `setCloExec`/`setNonBlocking`/`writeAll` triplicate | Refactor — no behavior change |
| Image size limits (50MB retina screenshots) | Needs UX design for user feedback |
| Paste interception robustness (NSTextView subclass) | Architecture change — careful AppKit work |
| Undo/image index desync | Complex state management — needs design |
| Add `os.Logger` throughout | Enhancement — no correctness impact |
| Error type unification across adapters | Refactor — no behavior change |
| Hardcoded PNG MIME type | Optimization — functional as-is |
| App-server stderr silently drained | Needs logging story first |
| fnm fallback scan (like nvm's version scan) | Low priority — symlink approach works |
| No UI feedback about queued images | UX enhancement |

### Key Context
- User runs fish shell and Ghostty terminal — use OSC-8 hyperlinks with `tput` styling
- User has LaunchAgent installed — always run `scripts/install` after code changes
- 4 binaries: `turbodraft` (Swift CLI), `turbodraft-app` (AppKit GUI), `turbodraft-open` (C fast-path), `turbodraft-editor` (bash $EDITOR shim)

## Reference Files

| File | Purpose |
|------|---------|
| `CLAUDE.md` | Project instructions for Claude Code |
| `README.md` | Open-source README |
| `Package.swift` | All module/product names |
| `Sources/TurboDraftCore/CommandResolver.swift` | PATH resolution, supplemental paths, shared `buildEnv` |
| `Sources/TurboDraftAgent/CodexPromptEngineerAdapter.swift` | Exec adapter — spawn, images |
| `Sources/TurboDraftAgent/CodexAppServerPromptEngineerAdapter.swift` | App-server adapter — spawn, images, base64 |
| `Sources/TurboDraftAgent/CodexCLIAgentAdapter.swift` | Basic CLI adapter |
| `Sources/TurboDraftApp/EditorViewController.swift` | Image paste handling, autosave, agent integration |
| `Tests/TurboDraftCoreTests/CommandResolverTests.swift` | New: CommandResolver + buildEnv tests |
| `Tests/TurboDraftAgentTests/CodexAdapterTests.swift` | Updated: images test added |
