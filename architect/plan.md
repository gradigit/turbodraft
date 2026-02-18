# TurboDraft v1 Implementation Plan

## Goal
Build a native macOS AppKit prompt editor for Claude/Codex external-editor hooks with near-zero latency activation and optional in-app AI prompt-improvement loop.

## Core requirements covered
- Sub-50ms startup/activation path target.
- Minimal single-file markdown-first editor UI.
- Debounced autosave (30–50ms) plus live file-watch sync.
- Conflict-safe behavior (newest-write-wins + explicit conflict banner + restore-to-last-saved).
- Optional pluggable AI agent add-on starting with local `codex` CLI subprocess.
- Transport via stdio JSON-RPC with optional Unix-domain socket daemon mode.
- Benchmarks and tests for perf, transport, sync, and agent-loop behavior.

## Decisions (default choices)
- Launch model: single resident editor instance with focus restore.
- Conflict strategy: newest-write-wins with explicit restore action.
- Agent drafting: snapshot-based drafts written via revision-gated file updates.
- Baseline policy: in-repo baseline JSON with manual re-baseline workflow.
- Agent backend default: `codex` subprocess adapter behind shared interface.

## Public interfaces

### JSON-RPC protocol
Shared envelope (internal): `jsonrpc`, `id`, `method`, `params`, `result`, `error`.

Methods:
1. `turbodraft/open` → returns session metadata, current file content, and revision.
2. `turbodraft/reload` → returns latest content for active session/file.
3. `turbodraft/save` → writes content with revision guard.
4. `turbodraft/watch.subscribe` → subscribe to file-write updates.
5. `turbodraft/agent/start` → begin draft pass.
6. `turbodraft/agent/stop` → cancel active draft pass.
7. `turbodraft/agent/draft` → draft event/callback payload.

### CLI contract
Commands:
- `turbodraft open --path <file>`
- `turbodraft --stdio`
- `turbodraft --socket --path <uds_path>`
- `turbodraft daemon --start|--stop`
- `turbodraft bench run --cold --warm --iterations N`
- `turbodraft config init`

Config file (JSON/TOML, lightweight):
- `editor_bundle_path`
- `socket_path`
- `autosave_debounce_ms` (default 40)
- `conflict_policy` (`newest_wins`)
- `agent.command` (default `codex`)
- `agent.args` (override-able)
- `agent.enabled` (bool)

## Repository layout to create
- `Sources/TurboDraft/AppKit/` — app process, window lifecycle.
- `Sources/TurboDraft/Transport/` — stdio + UDS transport, codec, validation.
- `Sources/TurboDraft/Editor/` — markdown styling + editor session state.
- `Sources/TurboDraft/Sync/` — watcher, autosave, conflict handling.
- `Sources/TurboDraft/Agent/` — agent protocol + `CodexCLIAdapter`.
- `Sources/TurboDraftCLI/` — CLI entrypoint and benchmark command.
- `Tests/Unit/` — formatting/autosave/conflict/transport tests.
- `Tests/Integration/` — CLI open/update and watcher sync tests.
- `Tests/Perf/` — startup and reflection benchmarks.
- `docs/` + `README.md`
- `.github/workflows/` for CI regression gates.
- `benchmarks/baselines.json`

## Execution phases

### Phase 1 — Foundation
1. Scaffold Swift package / app targets.
2. Add process singleton + activation lease.
3. Add config parsing and directory bootstrap.

### Phase 2 — Transport + CLI hook
1. Implement stdio JSON-RPC server and codec validation.
2. Add request handlers for `open/reload/save/watch.subscribe`.
3. Implement optional socket server and attach fallback path.
4. Implement activation and focus restore from CLI request.
5. Add protocol contract tests.

### Phase 3 — Minimal editor and markdown styling
1. Build single-window AppKit UI (no menus/settings panels).
2. Add markdown accent rendering for headers, emphasis, bullets, fences, inline code.
3. Ensure low-overhead incremental styling strategy.
4. Add file close/save reliability and clean shutdown handling.

### Phase 4 — Sync and conflict behavior
1. Add debounced autosave (30–50ms) with coalescing.
2. Add FS watcher + revision tracking.
3. Implement newest-write conflict banner and restore path.
4. Add session-level dirty/owned state and safe close behavior.

### Phase 5 — AI agent add-on
1. Add inline prompt/feedback pane.
2. Implement `AgentAdapter` interface.
3. Implement `CodexCLIAdapter` (streaming reads, timeout, malformed output guard).
4. Write draft snapshots through same save path using revision gating.
5. Preserve responsiveness; UI updates on main queue only.

### Phase 6 — Verification
1. Unit tests:
   - markdown rules
   - autosave coalescing
   - conflict resolution branches
   - message schema validation
2. Integration tests:
   - CLI open/save/update lifecycle
   - agent process writes and editor refresh
3. Perf tests:
   - repeated cold/warm launch, open, save, reflect loops
   - assert p95 thresholds:
     - `t_launch`
     - `t_ctrl_g_to_editable`
     - `t_autosave_p95`
     - `t_agent_reflect_p95`

### Phase 7 — Docs and CI
1. Add README usage for install and CLI bindings.
2. Add benchmark instructions and baseline update process.
3. Add CI job for lint/build/tests/bench thresholds.

## Acceptance checks
- Ctrl+G launch opens existing prompt file in editor and becomes editable quickly.
- Editor typing remains immediate with markdown accents applied.
- Autosave persists near-immediately and watcher updates reflect agent writes.
- Conflict path visible and recoverable.
- AI drafts are written and editable by user.
- Perf thresholds fail CI on regression against baseline.

## Risks / mitigations
- Cold-start variance: favor minimal AppKit startup path and resident socket mode.
- Watcher/autosave race: strict revision ordering + dedupe and banner.
- `codex` output quality/runtime variance: schema-guarded parsing + cancellation/retry.
