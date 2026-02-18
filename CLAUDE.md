# PromptPad — Claude Code Instructions

## Build and Install

After ANY code change (bug fix, feature, refactor), you MUST run `scripts/install` before testing or asking the user to verify. This rebuilds the release binary, re-symlinks, and restarts the LaunchAgent if installed.

```sh
scripts/install
```

The user has a LaunchAgent (`com.promptpad.app`) keeping `promptpad-app` resident. If you change app code and don't run `scripts/install`, the user will be running the OLD binary and will report issues that don't exist — leading you down a rabbit hole debugging code that's already been fixed.

Do NOT skip this step. Do NOT just run `swift build` — use `scripts/install` so the running agent gets restarted too.

## Commands

- `swift build` — debug build
- `swift build -c release` — release build
- `swift test` — run all tests (58 tests)
- `scripts/install` — build + symlink + restart LaunchAgent
- `scripts/promptpad-launch-agent install|uninstall|status|update|restart` — manage LaunchAgent
- `.build/release/promptpad bench run --path <file> --warm N --cold N` — editor benchmarks
- `.build/release/promptpad bench check --baseline bench/editor/baseline.json --results <file>` — check baselines
- `python3 scripts/bench_editor_e2e_ux.py --warm N --cold N` — end-to-end UX benchmark (needs Accessibility permissions)
- `pkill -9 -f promptpad-app && rm -f ~/Library/Application\ Support/PromptPad/rpc.sock` — kill stale processes + remove socket before benchmarks

## Architecture

Swift Package with 8 modules:

| Module | Purpose |
|--------|---------|
| `PromptPadApp` | macOS AppKit GUI — window, editor, menu, socket server |
| `PromptPadCLI` | CLI binary (`promptpad open`, `promptpad bench`) |
| `PromptPadOpen` | Minimal fast-path open binary (`promptpad-open`) |
| `PromptPadCore` | `EditorSession`, file I/O, directory watcher |
| `PromptPadProtocol` | JSON-RPC message types and method definitions |
| `PromptPadTransport` | Unix domain socket server/client, JSON-RPC framing |
| `PromptPadMarkdown` | Markdown syntax highlighting for NSTextView |
| `PromptPadAgent` | Codex prompt-engineering agent integration |
| `PromptPadConfig` | User config loading/saving |
| `PromptPadE2EHarness` | E2E benchmark harness binary |

Communication: CLI → Unix domain socket (`~/Library/Application Support/PromptPad/rpc.sock`) → App. JSON-RPC over content-length framed streams.

## Key Files

- `Sources/PromptPadApp/AppDelegate.swift` — app lifecycle, socket server, RPC dispatch, quit handling
- `Sources/PromptPadApp/EditorViewController.swift` — text editing, autosave, styling, agent integration
- `Sources/PromptPadApp/EditorWindowController.swift` — window management, session binding
- `Sources/PromptPadCLI/main.swift` — CLI entry point, benchmark runner, `connectOrLaunch`
- `Sources/PromptPadTransport/UnixDomainSocket.swift` — socket bind/listen/connect/accept
- `Sources/PromptPadCore/EditorSession.swift` — file session state, revision tracking
- `bench/editor/baseline.json` — benchmark regression thresholds

## Gotchas

- `NSNumber(value: 1)` matches Swift `as Bool` pattern due to ObjC bridging. Use `CFGetTypeID(n) == CFBooleanGetTypeID()` to distinguish booleans from integers in `JSONValue.fromJSONObject`.
- `terminate(nil)` enters `NSModalPanelRunLoopMode` which does NOT drain Swift concurrency Tasks. Do async cleanup BEFORE calling `terminate`, not inside `applicationWillTerminate` or `applicationShouldTerminate`.
- Benchmark baselines are machine-load sensitive. P95 thresholds need CI headroom — don't set tight values from dev-machine runs.
- Cold start (~170ms) is dominated by process startup (fork+exec+dyld+AppKit). Only the LaunchAgent eliminates it — early socket bind and kqueue don't help because the bottleneck is process bootstrap, not socket detection.
- Before benchmarks, kill stale `promptpad-app` processes and remove the socket. Stale processes cause the CLI to connect to an old binary.
- Bench lockfile (`~/Library/Application Support/PromptPad/bench.lock`) can get stuck if a run is interrupted — remove manually.
- Machine load heavily distorts benchmark p95s. Check `ps -eo %cpu,command -r | head -5` before chasing noisy regressions.
