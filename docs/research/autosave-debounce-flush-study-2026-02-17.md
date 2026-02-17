# Research: PromptPad autosave debounce/flush policy
Date: 2026-02-17
Depth: Full

## Executive Summary
For PromptPad’s Ctrl+G workflow, the strongest policy is: keep a short debounce for write coalescing (50ms default), add a hard max flush interval (250ms), and force flush on lifecycle boundaries (window close, app deactivate/hide/terminate, agent apply completion). This gives near-instant perceived save behavior without turning every keystroke into a disk write.

A strict 0ms debounce is technically possible but is not the best default for reliability/perf under real editor ecosystems where save events can fan out to additional work (watchers/tooling). Industry references show mainstream editors prefer delayed autosave or event-triggered save points, plus backup/recovery mechanisms.

Confidence: High for architecture direction, Medium for exact numeric sweet spot (must be tuned with your local benchmarks and workload).

## Sub-Questions Investigated
1. What autosave triggers are considered best practice for desktop editors?
2. Is 0ms debounce a good default, or should saves be coalesced?
3. What flush strategy prevents data loss while preserving typing responsiveness?
4. What recovery model best fits non-lossy prompt editing when users close/reopen?

## Detailed Findings

### 1) Autosave should be checkpoint-based, not manual-save dependent
- Apple guidance for single-window apps explicitly recommends automatic saves at meaningful checkpoints (close/quit, deactivation, hide, and valid data changes).
- VS Code and IntelliJ both expose event-driven autosave triggers (focus/window change, idle-based autosave), not only manual save.

Recommendation for PromptPad:
- Keep continuous autosave on edits (debounced).
- Add guaranteed flush points:
  - close window
  - app resign active/hide/terminate
  - before/after agent apply replacement

### 2) Debounce + max flush is the robust pattern
- Debounce primitives (delay + flush + maxWait) are a standard pattern for high-frequency events.
- VS Code defaults delayed autosave to 1000ms for general coding workflows and also supports focus/window-change save triggers.
- A prompt editor has smaller docs and stronger “never lose text” requirements, so shorter delays are justified than typical IDE defaults.

Recommendation for PromptPad:
- Debounce: 50ms default (user-visible instant, write coalescing retained).
- Max flush interval: 250ms (bounded staleness even during sustained typing).
- Optional presets:
  - ultra-safe: 30ms debounce, 150ms max flush
  - balanced: 50ms debounce, 250ms max flush (default)
  - low-IO: 100ms debounce, 400ms max flush

### 3) Keep editing responsiveness primary
- INP guidance: good responsiveness is <=200ms at the 75th percentile for interactions.
- Long synchronous save paths can interfere with responsiveness; Apple docs discuss asynchronous writing/snapshotting/cancellable autosaves as strategies to avoid UI blocking.

Recommendation for PromptPad:
- Do writes off the typing path (already mostly true).
- Ensure flush operations never block keystroke processing.
- Track:
  - edit-to-disk p50/p95
  - edit-to-saved-indicator p50/p95
  - keypress-to-paint latency p95 under save load

### 4) Non-lossy UX requires recoverability beyond in-session undo
- VS Code hot exit and IntelliJ local history both preserve recoverability beyond a single in-memory undo stack.
- Current PromptPad behavior is session-local undo/history, so close/reopen currently loses undo chain.

Recommendation for PromptPad:
- Add per-file persistent snapshot ring (local history lite) with TTL and size cap.
- Expose one-click restore from banner/menu if reopened after agent rewrite.
- Keep in-session undo unchanged; recovery store is fallback across process/window boundaries.

## Hypothesis Assessment

| Hypothesis | Confidence | Supporting Evidence | Contradicting Evidence |
|---|---|---|---|
| H1: 0ms debounce should be default for best UX | Low-Medium | Fastest raw persistence in microbenches | Save fan-out/tooling side effects; mainstream editors use delayed/event autosave |
| H2: 50ms debounce + bounded max flush gives best practical UX | High | Human-perception + INP budgets + editor autosave patterns + prompt workload characteristics | Exact numbers may vary by machine/workload |
| H3: Flush-on-close/quit alone is enough | Low | Covers app exit paths | Does not protect against mid-session crashes or cross-process writes |
| H4: Persistent recovery store is required for non-lossy philosophy | High | VS Code backups/hot exit + IntelliJ local history + user workflow risk profile | Extra complexity and storage management needed |

## Verification Status

### Verified (2+ sources)
- Autosave should happen automatically at checkpoints, not rely on manual save.
- Delayed and event-driven autosave are both standard approaches.
- Recovery beyond undo stack (backup/local history/hot exit style) is a standard anti-loss pattern.

### Unverified
- A universal best numeric debounce for all hardware/workloads.
- Whether 30ms beats 50ms for your exact p95 UX once full workload is included.

### Conflicts Resolved
- Conflict: “0ms is safest” vs “delay protects perf and tooling.”
- Resolution: Use short delay plus max flush and force flush on lifecycle boundaries. This keeps bounded durability while avoiding per-keystroke write amplification.

## Limitations & Gaps
- Public docs give architecture patterns but not a single canonical debounce number for native text editors.
- Final tuning still needs your editor-only benchmark suite with representative typing traces and parallel session load.

## Sources
| Source | URL | Quality | Accessed |
|---|---|---|---|
| VS Code Basic Editing (Auto Save + Hot Exit) | https://code.visualstudio.com/docs/editing/codebasics | High (official docs) | 2026-02-17 |
| VS Code 1.86 release notes (autosave + external tools behavior) | https://code.visualstudio.com/updates/v1_86 | High (official docs) | 2026-02-17 |
| Apple Mac App Programming Guide (automatic data-saving strategies) | https://developer.apple.com/library/archive/documentation/General/Conceptual/MOSXAppProgrammingGuide/CoreAppDesign/CoreAppDesign.html | High (official docs) | 2026-02-17 |
| Apple Document-Based App Guide (autosave in place, async/cancellable autosaves) | https://developer.apple.com/library/archive/documentation/DataManagement/Conceptual/DocBasedAppProgrammingGuideForOSX/StandardBehaviors/StandardBehaviors.html | High (official docs) | 2026-02-17 |
| lodash debounce reference (cancel/flush/maxWait model) | https://lodash.com/docs/#debounce | High (primary API doc) | 2026-02-17 |
| web.dev INP guidance | https://web.dev/articles/inp | High (Google web perf guidance) | 2026-02-17 |
| NN/g response-time limits | https://www.nngroup.com/articles/response-times-3-important-limits/ | Medium-High (industry UX authority) | 2026-02-17 |
| IntelliJ save/revert docs (autosave + local history) | https://www.jetbrains.com/help/idea/saving-and-reverting-changes.html | High (official docs) | 2026-02-17 |
