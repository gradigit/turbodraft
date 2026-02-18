# TurboDraft v1 Implementation Plan

## Goal
Build a native macOS AppKit prompt editor for Claude/Codex external-editor hooks with near-zero latency activation and optional in-app AI prompt-improvement loop.

## Core requirements covered
- Sub-50ms startup/activation path target.
- Define separate budgets for cold launch vs warm activation (resident instance is the primary path).
- Minimal single-file markdown-first editor UI.
- Debounced autosave (30–50ms) plus live file-watch sync (with measured p95 end-to-end latency budgets).
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

## macOS-native editor best practices (implementation notes)

### AppKit startup + activation (macOS 14+)
- Keep the activation path lean: defer anything non-essential (syntax grammar loading, agent adapters, indexing, network checks) until after the window is visible and the text view is editable.
- Implement the "reopen" behavior so repeated launches (Dock click, `open -a`, CLI) reliably surface an existing window via `applicationShouldHandleReopen(_:hasVisibleWindows:)`.
- Handle Launch Services open events for external-editor flows via `application(_:openFiles:)` and route to the existing session/window when already open.
- macOS Sonoma (14) introduced cooperative activation patterns and deprecates forceful focus stealing; treat focus as best-effort, and prefer user-attention fallbacks over retry loops.

### TextKit 2 editor core + incremental styling (markdown/syntax)
- Default to TextKit 2 (`NSTextView(usingTextLayoutManager: true)`) and avoid accidental downgrade to TextKit 1 compatibility mode.
- Guardrail: avoid accessing `layoutManager` (and other TextKit 1-only paths) on a TextKit 2 text view; switching to TextKit 1 is expensive and one-way.
- Styling strategy: keep it incremental (edited-range only), parse/tokenize off the main thread with cancellation, and apply attributes on the main thread in a single `beginEditing`/`endEditing` batch to minimize layout churn.
- Disable automatic content mutations that are surprising for prompts/code (smart quotes/dashes, automatic text replacement, autocorrect); keep spell-check optional.

### File watching + autosave + conflicts (atomic-save aware)
- Expect atomic-save semantics from other tools (write temp + rename/replace). Watching only a file descriptor often misses replacements; prefer watching the parent directory and re-resolving file identity.
- Prefer a directory-scoped watcher (FSEvents) for robust "file replaced" detection; treat events as hints and always re-stat/read to confirm.
- Maintain identity + revision metadata (`fileResourceIdentifierKey` + `mtime` and/or content hash) to drive reload vs conflict decisions.
- If you need coordination across processes (and especially if sandbox/iCloud enters the picture), consider `NSFilePresenter`/`NSFileCoordinator` semantics for safer read/write and external-change notifications.
- Suppress self-echo: tag autosave writes with an internal revision and ignore matching watcher events to avoid autosave-reflect loops.

### External editor integration (Claude/Codex hooks)
- Make the CLI ergonomic for external-editor callers: `turbodraft open --path <file> [--line N --column N] [--wait]`.
- Prefer a running-instance fast path: CLI connects to UDS and sends `turbodraft/open` + activation request; if not reachable, launch the app via Launch Services and retry connect with a short bounded backoff.
- Make `open` idempotent: opening an already-open path focuses the existing window and updates selection.

## Performance budgets & measurement methodology (deepened 2026-02-13)

### Definitions
- Cold launch: app process is not running; the CLI must start it (or `open` it) and wait for the editor to become editable.
- Warm activation: app process is already resident; a request arrives via UDS (preferred) or stdio and we only pay activation + file load + focus.
- Editable: the editor window is key + the text view is first responder + insertion point is visible + user keystrokes mutate the buffer.

### Metrics (names, start/end, target budgets)
- `t_launch` (cold): start = CLI begins `turbodraft open` with app not running; end = `Editable`.
- `t_ctrl_g_to_editable` (warm): start = transport receives `turbodraft/open`; end = `Editable`.
- `t_keystroke_p95`: start = `keyDown` (or `textDidChange`) timestamp; end = styling + text layout work complete for the edited range on the main thread.
- `t_autosave_p95`: start = last buffer mutation in a burst; end = autosave write completes (atomic replace) and revision is advanced.
- `t_file_reflect_p95` (a.k.a. `t_agent_reflect_p95`): start = file change event received (or agent write completion when known); end = editor buffer updated and view reflects the new revision (conflict banner if applicable).

Notes:
- Keep two perf tiers: (1) deterministic in-process microbenches (CI-friendly) and (2) end-to-end benches (noisier, better for local + dedicated runners).
- Keep budgets realistic: sub-50ms is for warm activation (resident app). Cold launch should be tracked separately and is expected to be slower.

### Instrumentation approach (low overhead, monotonic)
- Use a monotonic clock for all durations (`DispatchTime` / `ContinuousClock`), never `Date`, so clock adjustments don’t corrupt p95.
- Add an internal perf recorder that collects samples in memory and flushes once per benchmark run as JSON.
- Add `os_signpost` points-of-interest for key spans:
- `activate_to_editable`
- `keystroke_style_pass`
- `autosave_write`
- `file_event_to_apply`
- Compile instrumentation behind a flag (e.g., `PERF_METRICS`) so production builds aren’t paying for high-cardinality logging.

### Benchmark design (what we run, how we compute p95)
Scenarios (minimum set):
1. Startup/activation:
- Cold: N=20 (slow, noisy) with app fully terminated between iterations.
- Warm: N=200 (fast, stable) with resident app.
2. Keystroke latency:
- In-process benchmark that applies a representative edit pattern (single char insert, paste, newline) and runs the incremental styling pass.
- Run across 3 file sizes (e.g., ~2KB, ~20KB, ~100KB) to catch accidental O(n) restyling.
3. Autosave:
- Generate edit bursts, then measure end-to-end autosave latency per burst.
- Include one test where external process reads immediately after autosave completes (correctness + latency coupling).
4. File reflection:
- External writer performs atomic replacements in tight bursts; measure from event receipt to view update.
- Include “ignore self-writes” coverage to avoid autosave-reflect loops.

Percentiles:
- Compute p95/p99 from raw samples (don’t average averages).
- For CI decisions, prefer “median of p95 across 3 runs” over single-run p95 to reduce flake.

### Baselines and regression policy
- `benchmarks/baselines.json` stores per-metric thresholds and a baseline summary per environment tuple:
- Hardware model (or a runner ID), macOS version, Xcode version, build configuration.
- Gate on both:
- Absolute caps (hard SLOs for warm activation / keystrokes / autosave / reflect).
- Relative regressions vs baseline (e.g., fail if p95 regresses >20%).
- Manual re-baseline workflow:
- A dedicated command updates baselines with a required reason string (kept in JSON metadata).
- Baseline updates happen in a single-purpose PR so reviewers can sanity-check deltas.

### CI stability strategy (avoid flapping on hosted runners)
Recommended:
- Run perf gating on a pinned self-hosted macOS runner (stable hardware, stable OS/Xcode).
Fallback:
- On hosted runners, run microbenches as gating and keep end-to-end benches as advisory (or compare PR vs main in the same job to normalize machine drift).
Anti-flake measures:
- Rerun once automatically on regression before failing.
- Keep runtime bounded (fixed iteration counts), and record environment metadata with every run.

### Common pitfalls (design them out)
- “Sub-50ms startup” ambiguity: if cold + warm are mixed, you will chase the wrong bottleneck.
- Keystroke latency measurement via UI automation: UI tests include unrelated delays (event injection, accessibility, compositor) and are too noisy for micro targets.
- Full-document restyling on every keystroke: accidental O(n) behavior; enforce “edited-range only” styling and validate with the 100KB keystroke bench.
- Atomic writes vs watchers: non-atomic writes can be observed mid-write; require atomic replace for autosave and tolerate rename events in the watcher.
- Autosave/reflection feedback loops: your own writes will trigger your watcher; revision tagging must suppress self-reflection churn.
- Using wall-clock time (`Date`) for percentiles: clock jumps will create fake regressions.

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
- `turbodraft open --path <file> [--line N --column N] [--wait]`
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
4. Add AppKit lifecycle essentials (`applicationShouldHandleReopen`, `application(_:openFiles:)`, and secure-restorable-state support if you opt into state restoration).

### Phase 2 — Transport + CLI hook
1. Implement stdio JSON-RPC server and codec validation.
2. Add request handlers for `open/reload/save/watch.subscribe`.
3. Implement optional socket server and attach fallback path.
4. Implement activation and focus restore from CLI request.
5. Add protocol contract tests.
6. Add `open --wait` (optional) so external-editor callers can block until the session completes.

### Phase 3 — Minimal editor and markdown styling
1. Build single-window AppKit UI (no menus/settings panels).
2. Add markdown accent rendering for headers, emphasis, bullets, fences, inline code.
3. Ensure low-overhead incremental styling strategy.
4. Add file close/save reliability and clean shutdown handling.
5. TextKit 2 guardrails: instantiate `NSTextView(usingTextLayoutManager: true)` and audit code to avoid accidental TextKit 1 compatibility mode.

### Phase 4 — Sync and conflict behavior
1. Add debounced autosave (30–50ms) with coalescing.
2. Add FS watcher + revision tracking.
3. Implement newest-write conflict banner and restore path.
4. Add session-level dirty/owned state and safe close behavior.
5. Ensure watcher strategy survives atomic-save replacements (watch directory, re-resolve file identity).

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
     - `t_keystroke_p95`
     - `t_autosave_p95`
     - `t_file_reflect_p95` (aka `t_agent_reflect_p95`)

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
- Perf test flakiness (CI): prefer pinned runners, use microbench gating + median-of-p95 across multiple runs, and rerun-once before failing.
- macOS 14+ cooperative activation changes: treat focus as best-effort and build a graceful fallback when activation cannot be honored immediately.
