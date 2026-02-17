# PromptPad v1 Implementation Plan (Deepened)

This file is a deepened, research-backed enhancement of `plan.md`. The original `plan.md` is intentionally unchanged.

## Enhancement Summary

Deepened on: 2026-02-13

Plan input: `plan.md`

Output: `plan-deepened.md`

Sections enhanced:
- Goal and core requirements (external-editor contract, warm vs cold clarity)
- Transport and protocol (framing/versioning/errors/capabilities)
- File sync + autosave correctness (atomic replace, self-echo suppression, conflict behavior)
- Security baseline (UDS hardening, safe spawning, path validation, log redaction)
- Concurrency guardrails (AppKit + file watching + autosave + agent)
- Repo/tooling structure (SwiftPM core + minimal Xcode app wrapper)
- Release and verification (CI strategy + Go/No-Go checklist)

Research sources used:
- Architecture review: architecture-strategist
- Performance review: performance-oracle
- Security review: security-sentinel
- Agent-native parity review: agent-native-reviewer
- Race-condition review: julik-frontend-races-reviewer (translated to AppKit concurrency)
- Official docs sweep: framework-docs-researcher
- OSS repo structure: repo-research-analyst
- Naming consistency: pattern-recognition-specialist
- Release checklist: deployment-verification-agent

Leverageable institutional learnings:
- `docs/solutions/` not present in this repo (no local learnings to apply yet).

## Section Manifest

Section 1: Goal
- Research focus: external-editor contract and activation semantics on macOS; define success as "editable" rather than "frontmost".

Section 2: Core requirements covered
- Research focus: file watching correctness under atomic replace; TextKit 2 incremental styling performance posture.

Section 3: Decisions
- Research focus: make protocol framing/versioning/revision tokens/security decisions explicit and testable.

Section 4: macOS-native editor best practices
- Research focus: AppKit open/reopen/openFiles handlers; TextKit 2 guardrails; file coordination options.

Section 5: Performance budgets & measurement methodology
- Research focus: CI anti-flake patterns; warm vs cold gating; keystroke latency and file reflection measurement.

Section 6: Security baseline
- Research focus: UDS permissions, peer identity, path validation, safe subprocess spawn, non-leaky logging.

Section 7: Concurrency guardrails
- Research focus: race-proofing session state with epoching + single state owner; cancel-and-replace debouncers.

Section 8: Public interfaces
- Research focus: JSON-RPC framing and method naming; requests vs notifications; agent-native parity endpoints.

Section 9: CLI contract
- Research focus: `$EDITOR` semantics; `--wait`; connect-launch-retry; stable exit codes.

Section 10: Repository layout and execution phases
- Research focus: OSS-ready structure; SwiftPM vs Xcode split; CI layout.

Section 11: Acceptance, risks, and release checklist
- Research focus: verification completeness; rollback strategy; signing/notarization considerations.

## Goal

Build a native macOS AppKit prompt editor for Claude/Codex external-editor hooks with near-zero latency activation and optional in-app AI prompt-improvement loop.

### Research Insights

Best Practices:
- Treat external-editor compatibility as a contract: the invocation must be able to block until the user is done (`--wait` or session wait RPC), otherwise CLI hooks can return early and drop edits.
- Separate cold-launch metrics from warm-activation metrics; the sub-50ms experience is realistically achieved via a resident-instance activation path.

Performance Considerations:
- Define "success" for latency as `Editable` (window key + text view first responder + insertion point visible), not "focused/frontmost".

Implementation Details:
- Make the CLI open path idempotent: opening an already-open prompt should focus/raise the existing window and update selection.

Edge Cases:
- macOS activation can be best-effort; do not hard-block the CLI on "frontmost focus". Block on "session finished" (`--wait`) and treat activation as a user-experience best effort.

References:
- NSApplicationDelegate open/reopen handling: https://developer.apple.com/documentation/appkit/nsapplicationdelegate?language=objc
- `applicationShouldHandleReopen(_:hasVisibleWindows:)`: https://developer.apple.com/documentation/appkit/nsapplicationdelegate/applicationshouldhandlereopen%28_%3Ahasvisiblewindows%3A%29?language=objc
- `application(_:openFiles:)`: https://developer.apple.com/documentation/appkit/nsapplicationdelegate/application%28_%3Aopenfiles%3A%29

## Core requirements covered

- Sub-50ms startup/activation path target.
- Define separate budgets for cold launch vs warm activation (resident instance is the primary path).
- Minimal single-file markdown-first editor UI.
- Debounced autosave (30–50ms) plus live file-watch sync (with measured p95 end-to-end latency budgets).
- Conflict-safe behavior (newest-write-wins + explicit conflict banner + restore-to-last-saved).
- Optional pluggable AI agent add-on starting with local `codex` CLI subprocess.
- Transport via stdio JSON-RPC with optional Unix-domain socket daemon mode.
- Benchmarks and tests for perf, transport, sync, and agent-loop behavior.

### Research Insights

Best Practices:
- Default to TextKit 2 for modern text layout, but treat it as an invariant: avoid compatibility-mode triggers (notably TextKit 1-only entrypoints).
- File watching must assume "atomic replace" semantics from other tools; watching only a file descriptor is not robust.

Performance Considerations:
- Make `t_keystroke` a first-class metric and gate incremental styling on edited-range-only updates.

Edge Cases:
- Self-echo: autosave writes trigger watcher reads unless you suppress based on a write-stamp (hash/size/resource identifier).

References:
- TextKit 2 overview (WWDC22): https://developer.apple.com/videos/play/wwdc2022/10090/
- NSTextView docs: https://developer.apple.com/documentation/appkit/nstextview?language=objc
- FSEvents guide: https://developer.apple.com/library/archive/documentation/Darwin/Conceptual/FSEvents_ProgGuide/UsingtheFSEventsFramework/UsingtheFSEventsFramework.html
- Dispatch file system sources: https://developer.apple.com/documentation/dispatch/dispatchsource/makefilesystemobjectsource%28filedescriptor%3Aeventmask%3Aqueue%3A%29

## Decisions (default choices)

Original decisions (preserved):
- Launch model: single resident editor instance with focus restore.
- Conflict strategy: newest-write-wins with explicit restore action.
- Agent drafting: snapshot-based drafts written via revision-gated file updates.
- Baseline policy: in-repo baseline JSON with manual re-baseline workflow.
- Agent backend default: `codex` subprocess adapter behind shared interface.

Deepened decisions (make explicit in v1 implementation):
- Minimum macOS version: macOS 13+ (recommended). If macOS 12 is required, treat as a scoped change (TextKit 2 and activation behavior assumptions shift).
- Config format: JSON only.
- Config precedence: CLI flags > env vars > config file > defaults.
- JSON-RPC framing over streams: LSP-style `Content-Length` headers.
- Protocol versioning: `promptpad.hello` handshake returns `protocol_version=1` and capability flags.
- Method naming: canonical dot-separated namespaces, with aliases for legacy names if needed.
- Revision token: `sha256:<hex>` of on-disk content.
- Save policy: session-bound writes only (no write-anywhere path in RPC).
- File write strategy: atomic replace (temp + replace) for autosave; watcher must handle replace.
- UDS hardening baseline:
  - socket directory `0700`
  - socket file `0600`
  - peer uid check (`getpeereid`)
  - close-on-exec for all sockets
  - optional Keychain token for privileged methods
- `codex` spawn baseline:
  - never spawn via shell
  - pass prompt via stdin (not argv)
  - timeout + max output bytes
  - redact logs (no prompt/file contents)

### Research Insights

Best Practices:
- Any "decision" should be testable: framing parser fuzz tests, socket permissions tests, path canonicalization tests, and revision conflict tests.

References:
- JSON-RPC spec: https://www.jsonrpc.org/specification
- LSP framing reference (for Content-Length over streams): https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/

## macOS-native editor best practices (implementation notes)

Original content (preserved from `plan.md`):

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
- Make the CLI ergonomic for external-editor callers: `promptpad open --path <file> [--line N --column N] [--wait]`.
- Prefer a running-instance fast path: CLI connects to UDS and sends `promptpad/open` + activation request; if not reachable, launch the app via Launch Services and retry connect with a short bounded backoff.
- Make `open` idempotent: opening an already-open path focuses the existing window and updates selection.

### Research Insights

Best Practices:
- If using Apple Event "open file" paths, reply via `NSApplication.reply(toOpenOrPrint:)` where applicable to give Launch Services a completion status.
- Prefer best-effort activation and have a fallback (dock bounce or attention request) rather than retry loops that can stall the CLI.

References:
- `reply(toOpenOrPrint:)`: https://developer.apple.com/documentation/appkit/nsapplication/reply%28toopenorprint%3A%29?language=objc
- `activate(ignoringOtherApps:)`: https://developer.apple.com/documentation/appkit/nsapplication/activate%28ignoringotherapps%3A%29?language=objc
- `NSWorkspace.OpenConfiguration`: https://developer.apple.com/documentation/appkit/nsworkspace/openconfiguration

## Performance budgets & measurement methodology (deepened 2026-02-13)

Original content (preserved from `plan.md`): this section already contains the deepened performance plan. The additions below clarify naming and CI gating strategy.

### Additional Research Insights

Best Practices:
- Keep metric keys percentile-agnostic in storage schema (store p50/p95/p99 as values). This avoids proliferating metric names as you expand percentiles.
- Prefer stable in-process microbenches for keystroke and styling and treat end-to-end UI benches as advisory unless you have pinned hardware.

Implementation Details:
- Baseline schema should include an environment tuple:
  - `hardware_id`, `macos_version`, `xcode_version`, `build_config`
- Regression policy should support both:
  - absolute caps
  - relative regression thresholds (for example +20% p95)

References:
- `os_signpost` docs: https://developer.apple.com/documentation/os/signposts

## Security baseline (deepened 2026-02-13)

Trust boundaries:
- stdio client (parent process)
- UDS client (any local process that can connect)
- filesystem paths (untrusted input)
- `codex` subprocess output (untrusted content)

UDS hardening:
- Socket path defaults under `~/Library/Application Support/PromptPad/` (directory perms `0700`).
- Socket file perms `0600` and peer uid check via `getpeereid()`; reject non-matching uid.
- Refuse to unlink a pre-existing socket path unless it is a socket owned by current uid.
- Set `FD_CLOEXEC` on listening socket and accepted client sockets.
- Optional auth token for privileged RPC methods:
  - generate a random token on first run
  - store in Keychain (preferred) or a `0600` file under Application Support
  - require it for `save` and `agent.*` when using UDS mode

Path validation and safe writes:
- Canonicalize incoming paths:
  - absolute path required
  - `standardizedFileURL` + `resolvingSymlinksInPath`
- Only allow regular files; reject directories/devices. Enforce a max file size on load.
- Prevent "write-anywhere": `save` writes only to the path bound to the session.
- Prefer safe open patterns to reduce symlink/TOCTOU issues (`O_NOFOLLOW`, validate with `fstat`).
- Autosave should use atomic replace and preserve permissions.

Safe `codex` spawning:
- Never spawn via a shell.
- Prefer absolute path resolved at `config init` (warn if only a bare `codex` name is configured).
- Pass prompt via stdin (not argv).
- Enforce timeout + max output bytes; strict parsing.
- Never log prompt contents, file contents, tokens, or full paths. Use `os.Logger` privacy or avoid logging sensitive values entirely.

References:
- Process docs: https://developer.apple.com/documentation/foundation/process
- File presenters/coordinators guide: https://developer.apple.com/library/archive/documentation/FileManagement/Conceptual/FileSystemProgrammingGuide/FileCoordinators/FileCoordinators.html

## Concurrency / race-condition guardrails (deepened)

These rules are designed to keep AppKit UI responsive while file watching, autosave, and agent writes run concurrently.

Guardrails:
- Session epoching: maintain `sessionEpoch` and discard async results for stale epochs.
- Single state owner: put canonical session state behind an `actor` or one serial queue; all sources enqueue intents.
- Explicit state machine: define allowed transitions (`idle`, `dirtyEditing`, `autosaving`, `applyingExternal`, `conflictShowing`, `agentApplying`).
- Cancel-and-replace debouncers: timers/tasks must be cancelable and canceled on teardown/reschedule.
- Coalesce watcher bursts and apply only "latest stable" change.
- Self-echo suppression based on a write-stamp (hash + size + resource id when available), not "ignore next event".
- Read stability checks for non-atomic external writers (size/mtime stable across a short delay) or use coordination APIs when appropriate.
- Conflict detection should not rely solely on wall-clock timestamps; use revision tokens/stamps.
- Main-thread rules: heavy work off-main, UI and TextKit mutations on `@MainActor` only.
- Styling tasks must be revision-gated (discard if buffer changed).
- Teardown hygiene: watchers/observers/tasks/subprocess pipes must be owned by a lifecycle bag and canceled on session close.
- Agent output must go through the same save/apply pipeline as user edits (so ordering and suppression rules apply).

## Public interfaces

### JSON-RPC protocol

Original method list (preserved from `plan.md`):
1. `promptpad/open` → returns session metadata, current file content, and revision.
2. `promptpad/reload` → returns latest content for active session/file.
3. `promptpad/save` → writes content with revision guard.
4. `promptpad/watch.subscribe` → subscribe to file-write updates.
5. `promptpad/agent/start` → begin draft pass.
6. `promptpad/agent/stop` → cancel active draft pass.
7. `promptpad/agent/draft` → draft event/callback payload.

Deepened transport framing (required):
- JSON-RPC does not define message delimiters on byte streams. Adopt Content-Length framing:
```text
Content-Length: <bytes>\r
\r
<JSON body>
```

Deepened versioning and capabilities:
- Add `promptpad.hello` request:
  - returns `protocol_version`, `capabilities`, and `server_pid`.
- Add `promptpad.capabilities` request:
  - returns supported methods/notifications so clients can adapt.

Agent-native parity additions (recommended):
- Drafts as first-class resources:
  - `promptpad.draft.create`
  - `promptpad.draft.list`
  - `promptpad.draft.get`
  - `promptpad.draft.apply` (accept)
  - `promptpad.draft.discard` (reject)
- History/restore endpoints:
  - `promptpad.history.list`
  - `promptpad.history.restore`
- Session wait contract (for CLI `--wait`):
  - `promptpad.session.wait`

Requests vs notifications:
- Requests are verb-shaped: `promptpad.session.open`, `promptpad.session.save`.
- Notifications are did_* shaped: `promptpad.session.did_change`, `promptpad.agent.did_draft`, `promptpad.conflict.detected`.

Method naming normalization (recommendation):
- Canonicalize to dot-separated namespaces:
  - `promptpad/open` alias -> `promptpad.session.open`
  - `promptpad/reload` alias -> `promptpad.session.reload`
  - `promptpad/save` alias -> `promptpad.session.save`
  - `promptpad/watch.subscribe` -> `promptpad.session.subscribe`
  - `promptpad/agent/start` -> `promptpad.agent.start`
  - `promptpad/agent/stop` -> `promptpad.agent.stop`
  - `promptpad/agent/draft` -> `promptpad.agent.did_draft` (if treated as a notification)

Error codes (stable):
- `E_NOT_READY`, `E_INVALID_PARAMS`, `E_NOT_FOUND`, `E_CONFLICT`, `E_IO`, `E_TIMEOUT`, `E_CANCELED`, `E_UNAUTHORIZED`

Hardening requirements:
- Enforce max message size (for example 5MB).
- Enforce max file size on open (for example 2MB) unless explicitly configured.
- JSON-RPC reserved prefix rule: do not define methods starting with `rpc.`.

References:
- JSON-RPC spec: https://www.jsonrpc.org/specification
- LSP framing reference: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/

### CLI contract

Original commands (preserved from `plan.md`):
- `promptpad open --path <file> [--line N --column N] [--wait]`
- `promptpad --stdio`
- `promptpad --socket --path <uds_path>`
- `promptpad daemon --start|--stop`
- `promptpad bench run --cold --warm --iterations N`
- `promptpad config init`

Deepened CLI semantics:
- Default `$EDITOR` behavior:
  - `promptpad <file>` should behave like `promptpad open --path <file> --wait`.
- `--wait` contract:
  - block until the session ends (window closed) or `--timeout-ms` expires
  - return non-zero exit code on transport/protocol errors
- Connection strategy:
  - try UDS fast path
  - if connect fails, launch app via Launch Services and retry connect with bounded backoff until timeout
  - once connected, run `promptpad.hello` then `promptpad.session.open` then `promptpad.session.wait`
- Exit codes:
  - map error codes to deterministic CLI exit codes (document the mapping)

Suggested environment variables:
- `PROMPTPAD_SOCKET` (override socket path)
- `PROMPTPAD_CONFIG` (override config path)
- `PROMPTPAD_LOG_LEVEL` (optional; default info)

## Repository layout to create

Original layout (preserved from `plan.md`):
- `Sources/PromptPad/AppKit/` — app process, window lifecycle.
- `Sources/PromptPad/Transport/` — stdio + UDS transport, codec, validation.
- `Sources/PromptPad/Editor/` — markdown styling + editor session state.
- `Sources/PromptPad/Sync/` — watcher, autosave, conflict handling.
- `Sources/PromptPad/Agent/` — agent protocol + `CodexCLIAdapter`.
- `Sources/PromptPadCLI/` — CLI entrypoint and benchmark command.
- `Tests/Unit/` — formatting/autosave/conflict/transport tests.
- `Tests/Integration/` — CLI open/update and watcher sync tests.
- `Tests/Perf/` — startup and reflection benchmarks.
- `docs/` + `README.md`
- `.github/workflows/` for CI regression gates.
- `benchmarks/baselines.json`

Deepened OSS-ready structure (recommended):
- SwiftPM as source of truth for core libs + CLI + tests:
  - `Package.swift`
  - `Sources/PromptPadCore/`
  - `Sources/PromptPadTransport/`
  - `Sources/PromptPadProtocol/`
  - `Sources/PromptPadAgent/`
  - `Sources/PromptPadCLI/`
  - `Tests/PromptPadCoreTests/`
  - `Tests/PromptPadIntegrationTests/`
- Minimal Xcode project for the `.app` bundle:
  - `App/PromptPad.xcodeproj/`
  - `App/PromptPad/` (Info.plist, entitlements, icons, AppKit UI sources)
- OSS hygiene:
  - `README.md`, `LICENSE`, `CONTRIBUTING.md`, `CODE_OF_CONDUCT.md`, `SECURITY.md`, `CHANGELOG.md`

## Execution phases

### Phase 1 — Foundation
1. Scaffold Swift package + minimal Xcode app project that depends on it.
2. Add process singleton + activation lease.
3. Add config parsing and directory bootstrap.
4. Add AppKit lifecycle essentials (`applicationShouldHandleReopen`, `application(_:openFiles:)`).
5. Add perf instrumentation points early (so later phases are measurable).

### Phase 2 — Transport + CLI hook
1. Implement Content-Length framing (stdio + UDS).
2. Add `promptpad.hello` handshake and stable error codes.
3. Add request handlers for `open/reload/save` and `session.wait` for `--wait`.
4. Implement UDS hardening:
  - permissions and peer identity check
  - close-on-exec
  - optional auth token for privileged methods
5. Add fuzz/negative tests for framing (partial reads, oversized payloads).

### Phase 3 — Minimal editor and markdown styling
1. Build single-window AppKit UI (no menus/settings panels).
2. Confirm TextKit 2 is active and guard against compatibility-mode triggers.
3. Implement incremental markdown accents:
  - edited-range parsing off-main
  - cancel stale passes
  - batch apply on main
4. Turn off disruptive automatic substitutions by default.

### Phase 4 — Sync and conflict behavior
1. Add debounced autosave (30–50ms) with coalescing.
2. Implement directory-level watching (FSEvents preferred) and re-resolve file identity on events.
3. Implement self-echo suppression using write-stamps.
4. Implement newest-write-wins conflict banner plus restore action backed by a snapshot ring.
5. Ensure behavior is deterministic under atomic replace and in-place writes.

### Phase 5 — AI agent add-on
1. Add inline prompt/feedback pane.
2. Implement `AgentAdapting` interface and `CodexCLIAgentAdapter`.
3. Spawn `codex` safely (stdin input, timeout, output caps).
4. Treat agent results as drafts:
  - create draft resource
  - allow accept/reject
  - always snapshot before apply

### Phase 6 — Verification
1. Unit tests:
  - markdown rules
  - autosave coalescing
  - conflict resolution branches
  - JSON-RPC framing/parser validation
  - path canonicalization and rejections
2. Integration tests:
  - CLI open/wait/save lifecycle
  - UDS permissions and peer identity (where testable)
  - external atomic replace -> editor reflection
  - agent subprocess output -> draft accept/reject
3. Perf tests:
  - cold/warm open-to-editable
  - keystroke-to-styled across file sizes
  - edit burst to autosave (p95)
  - external change to view (p95)
  - baseline regression gates (p95 thresholds)

### Phase 7 — Docs, CI, and release
1. Add README and protocol/benchmark docs in `docs/`.
2. Add CI workflow:
  - `swift test`
  - `swift build -c release`
  - `xcodebuild build` for the app project
3. Add perf workflow:
  - advisory on hosted runners
  - gating only on pinned self-hosted macOS runner, comparing to `benchmarks/baselines.json`
4. Add release Go/No-Go checklist (below) and document signing/notarization expectations for distribution.

## Acceptance checks

Original acceptance checks (preserved from `plan.md`):
- Ctrl+G launch opens existing prompt file in editor and becomes editable quickly.
- Editor typing remains immediate with markdown accents applied.
- Autosave persists near-immediately and watcher updates reflect agent writes.
- Conflict path visible and recoverable.
- AI drafts are written and editable by user.
- Perf thresholds fail CI on regression against baseline.

Additional acceptance checks (deepened):
- `promptpad open --path <file> --wait` blocks until the session ends (external editor contract).
- UDS socket directory is `0700` and socket file is `0600`; non-matching uid connections are rejected.
- `save` is session-bound; cannot write to arbitrary file paths.
- `codex` is spawned without a shell and prompt is passed via stdin; output caps and timeout enforced.
- Framing parser handles partial reads and oversized payloads deterministically.

## Risks / mitigations

Original risks (preserved from `plan.md`):
- Cold-start variance: favor minimal AppKit startup path and resident socket mode.
- Watcher/autosave race: strict revision ordering + dedupe and banner.
- `codex` output quality/runtime variance: schema-guarded parsing + cancellation/retry.
- Perf test flakiness (CI): prefer pinned runners, use microbench gating + median-of-p95 across multiple runs, and rerun-once before failing.
- macOS 14+ cooperative activation changes: treat focus as best-effort and build a graceful fallback when activation cannot be honored immediately.

Additional risks (deepened):
- Message framing bugs in stream transports: mitigate via Content-Length framing, fuzz tests, and strict max message sizes.
- Atomic replace breaking file watchers: mitigate via directory-level watchers and file identity re-resolution per event burst.
- Stale async tasks applying to new sessions: mitigate via epoching and single-state-owner pattern (actor/queue).

## Release Go/No-Go Checklist (deepened)

Use this checklist for tagged releases (and optionally for internal RCs).

Release gates:
- Versioning and metadata set (bundle version, CLI version, SHA recorded).
- Release build passes unit/integration tests.
- Bench metrics meet absolute caps and do not regress beyond threshold.
- Distribution choice confirmed:
  - Direct download: code signing and notarization verified.
  - Mac App Store: App Store Connect compliance completed.

Signing/notarization checks (if direct download):
- `codesign --verify --deep --strict` passes.
- `spctl --assess --type execute` passes.
- Notarization succeeds and is stapled.

Smoke tests on shipped artifact:
- Fresh install works (Gatekeeper OK).
- Upgrade from prior version preserves config and works.
- External editor flow works (`--wait`).
- Conflict banner + restore works under forced external writes.

Rollback plan:
- Direct download: pull bad artifact and re-publish prior stable.
- Auto-update feed (if added later): pull entry or ship hotfix with higher version.

## References

Protocol:
- JSON-RPC 2.0: https://www.jsonrpc.org/specification
- LSP 3.17 framing reference: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/

AppKit:
- NSApplicationDelegate: https://developer.apple.com/documentation/appkit/nsapplicationdelegate?language=objc
- `applicationShouldHandleReopen(_:hasVisibleWindows:)`: https://developer.apple.com/documentation/appkit/nsapplicationdelegate/applicationshouldhandlereopen%28_%3Ahasvisiblewindows%3A%29?language=objc
- `application(_:openFiles:)`: https://developer.apple.com/documentation/appkit/nsapplicationdelegate/application%28_%3Aopenfiles%3A%29
- `activate(ignoringOtherApps:)`: https://developer.apple.com/documentation/appkit/nsapplication/activate%28ignoringotherapps%3A%29?language=objc
- `NSWorkspace.OpenConfiguration`: https://developer.apple.com/documentation/appkit/nsworkspace/openconfiguration

Text:
- TextKit 2 overview (WWDC22): https://developer.apple.com/videos/play/wwdc2022/10090/
- NSTextView: https://developer.apple.com/documentation/appkit/nstextview?language=objc
- NSTextLayoutManager: https://developer.apple.com/documentation/appkit/nstextlayoutmanager

File watching and coordination:
- FSEvents guide: https://developer.apple.com/library/archive/documentation/Darwin/Conceptual/FSEvents_ProgGuide/UsingtheFSEventsFramework/UsingtheFSEventsFramework.html
- Dispatch file system sources: https://developer.apple.com/documentation/dispatch/dispatchsource/makefilesystemobjectsource%28filedescriptor%3Aeventmask%3Aqueue%3A%29
- File coordination guide: https://developer.apple.com/library/archive/documentation/FileManagement/Conceptual/FileSystemProgrammingGuide/FileCoordinators/FileCoordinators.html
- NSFilePresenter: https://developer.apple.com/documentation/foundation/nsfilepresenter
- NSFileCoordinator: https://developer.apple.com/documentation/foundation/nsfilecoordinator

Perf instrumentation:
- `os_signpost`: https://developer.apple.com/documentation/os/signposts
