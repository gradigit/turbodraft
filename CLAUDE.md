# TurboDraft — Claude Code Instructions

## Build and Install

After ANY code change (bug fix, feature, refactor), you MUST run `scripts/install` before testing or asking the user to verify. This rebuilds the release binary, re-symlinks, and restarts the LaunchAgent if installed.

```sh
scripts/install
```

The user has a LaunchAgent (`com.turbodraft.app`) keeping `turbodraft-app` resident. If you change app code and don't run `scripts/install`, the user will be running the OLD binary and will report issues that don't exist — leading you down a rabbit hole debugging code that's already been fixed.

Do NOT skip this step. Do NOT just run `swift build` — use `scripts/install` so the running agent gets restarted too.

## Commands

- `swift build` — debug build
- `swift build -c release` — release build
- `swift test` — run all tests (67 tests)
- `scripts/install` — build + symlink + restart LaunchAgent
- `scripts/turbodraft-launch-agent install|uninstall|status|update|restart` — manage LaunchAgent
- `.build/release/turbodraft bench run --path <file> --warm N --cold N` — editor benchmarks
- `.build/release/turbodraft bench check --baseline bench/editor/baseline.json --results <file>` — check baselines
- `python3 scripts/bench_editor_e2e_ux.py --warm N --cold N` — end-to-end UX benchmark (needs Accessibility permissions)
- `pkill -9 -f turbodraft-app && rm -f ~/Library/Application\ Support/TurboDraft/rpc.sock` — kill stale processes + remove socket before benchmarks

## Architecture

Swift Package with 10 modules:

| Module | Purpose |
|--------|---------|
| `TurboDraftApp` | macOS AppKit GUI — window, editor, menu, socket server |
| `TurboDraftCLI` | CLI binary (`turbodraft open`, `turbodraft bench`) |
| `TurboDraftOpen` | Minimal fast-path open binary (`turbodraft-open`) |
| `TurboDraftCore` | `EditorSession`, file I/O, directory watcher |
| `TurboDraftProtocol` | JSON-RPC message types and method definitions |
| `TurboDraftTransport` | Unix domain socket server/client, JSON-RPC framing |
| `TurboDraftMarkdown` | Markdown syntax highlighting for NSTextView |
| `TurboDraftAgent` | Codex prompt-engineering agent integration |
| `TurboDraftConfig` | User config loading/saving |
| `TurboDraftE2EHarness` | E2E benchmark harness binary |

Communication: CLI → Unix domain socket (`~/Library/Application Support/TurboDraft/rpc.sock`) → App. JSON-RPC over content-length framed streams.

## Key Files

- `Sources/TurboDraftApp/AppDelegate.swift` — app lifecycle, socket server, RPC dispatch, quit handling
- `Sources/TurboDraftApp/EditorViewController.swift` — text editing, autosave, styling, agent integration
- `Sources/TurboDraftApp/EditorWindowController.swift` — window management, session binding
- `Sources/TurboDraftCLI/main.swift` — CLI entry point, benchmark runner, `connectOrLaunch`
- `Sources/TurboDraftTransport/UnixDomainSocket.swift` — socket bind/listen/connect/accept
- `Sources/TurboDraftCore/EditorSession.swift` — file session state, revision tracking
- `Sources/TurboDraftCore/CommandResolver.swift` — PATH resolution, supplemental paths (nvm/fnm/homebrew), shared `buildEnv`
- `bench/editor/baseline.json` — benchmark regression thresholds

## Gotchas

- `NSNumber(value: 1)` matches Swift `as Bool` pattern due to ObjC bridging. Use `CFGetTypeID(n) == CFBooleanGetTypeID()` to distinguish booleans from integers in `JSONValue.fromJSONObject`.
- `terminate(nil)` enters `NSModalPanelRunLoopMode` which does NOT drain Swift concurrency Tasks. Do async cleanup BEFORE calling `terminate`, not inside `applicationWillTerminate` or `applicationShouldTerminate`.
- Benchmark baselines are machine-load sensitive. P95 thresholds need CI headroom — don't set tight values from dev-machine runs.
- Cold start (~170ms) is dominated by process startup (fork+exec+dyld+AppKit). Only the LaunchAgent eliminates it — early socket bind and kqueue don't help because the bottleneck is process bootstrap, not socket detection.
- Before benchmarks, kill stale `turbodraft-app` processes and remove the socket. Stale processes cause the CLI to connect to an old binary.
- Bench lockfile (`~/Library/Application Support/TurboDraft/bench.lock`) can get stuck if a run is interrupted — remove manually.
- Machine load heavily distorts benchmark p95s. Check `ps -eo %cpu,command -r | head -5` before chasing noisy regressions.
- `TurboDraftOpen` is plain C (`main.c`), not Swift. All three agent adapters share spawn helpers (`setCloExec`/`setNonBlocking`/`writeAll`) — they're intentionally inlined per-file to avoid adding a shared C shim target.
- All agent adapters must use `CommandResolver.buildEnv(prependingToPath:)` when spawning child processes. Using raw `environ` directly skips PATH enrichment and breaks under the LaunchAgent.
