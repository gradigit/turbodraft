# Research: Editor autosave debounce/flush strategy for PromptPad
Date: 2026-02-17
Depth: Full

## Executive Summary

For PromptPad’s low-friction editor workflow, `0ms` debounce is not the best default. It maximizes write frequency and can amplify downstream watcher/actions-on-save churn. A better design is:

- trailing debounce in the low tens of milliseconds
- bounded max flush interval
- forced flush on close/quit/agent-run boundaries
- durable recovery history for non-lossy restore across reopen

Confidence: High (method-level); Medium (exact millisecond sweet spot, which should be validated with repo benchmarks).

## Sub-Questions Investigated

1. What do mainstream editor ecosystems indicate about autosave behavior?
2. What does platform guidance (Apple/macOS) suggest for autosave frequency and UX safety?
3. What debounce/flush control pattern is considered robust?
4. What recovery model best supports non-lossy behavior when autosave/agent output is wrong?

## Detailed Findings

### 1) Autosave should be frequent but not “every single change immediately”

- Apple’s document guidance explicitly says the system does not save every change immediately, but saves often enough at correct times to keep in-memory and on-disk effectively aligned.
- Apple also warns autosave can block UI if saving is slow, and calls out performance considerations and cancellable autosaves.

Interpretation for PromptPad:
- Avoid `0ms` write-on-every-keystroke as a default.
- Keep writes frequent enough for external-editor correctness, but coalesced.

### 2) Save triggers can cascade into expensive downstream actions

- JetBrains docs state autosave can trigger actions-on-save and other workflows.
- VS Code added an option to suppress autosave when errors exist specifically to avoid external tools acting on bad intermediate states.

Interpretation for PromptPad:
- Frequent raw disk writes can trigger watchers/tooling churn.
- Coalescing plus explicit boundary flush (close/quit/agent run) reduces churn without sacrificing reliability.

### 3) Debounce + maxWait is the robust control pattern

- Debounce reduces operation frequency during bursts.
- Lodash documentation formalizes `maxWait` to guarantee execution isn’t delayed indefinitely during continuous input, plus `flush()` for explicit immediate commit.

Interpretation for PromptPad:
- Use trailing debounce for normal typing.
- Add max flush interval to cap unsaved window during nonstop typing.
- Use explicit flush hooks for lifecycle boundaries.

### 4) Non-lossy recovery should not depend solely on same-session Undo

- JetBrains positions Local History as a robust fallback beyond immediate undo.
- VS Code Hot Exit restores backed-up unsaved work across exit/crash.

Interpretation for PromptPad:
- Cross-reopen undo via native text undo stack is not sufficient by itself.
- Add persistent, per-file restore checkpoints (original-on-open, pre-agent-apply, recent autosave snapshots).

## Hypothesis Tracking

| Hypothesis | Confidence | Supporting Evidence | Contradicting Evidence |
|---|---|---|---|
| H1: `0ms` debounce is best for UX | Low | None strong | Apple warns about autosave performance/periodic blocking; web.dev warns recurring timer/task pressure can increase input delay |
| H2: Small debounce + max flush + lifecycle flush gives best practical reliability/latency balance | High | Debounce guidance + `maxWait` pattern + platform autosave timing guidance | Exact numeric sweet spot still implementation-specific |
| H3: Persistent history is required for non-lossy philosophy across close/reopen | High | JetBrains Local History + VS Code Hot Exit restore pattern | None meaningful |

## Verification Status

### Verified (2+ sources)

- Frequent writes can have side effects via save-triggered actions/watchers.
- Autosave should be reliable and regular, but not naïvely “every mutation immediately”.
- Durable recovery beyond in-session undo is a best-practice pattern.

### Unverified

- A universal “one true debounce value” across all editor stacks (not found; should be benchmarked in-context).

### Conflicts Resolved

- Some ecosystems default to longer autosave delays (example 1000ms); PromptPad’s external-editor latency target justifies shorter values.
- Resolution: keep short debounce but add max flush and boundary flush.

## Recommended Target Policy for PromptPad (inference from sources + product goals)

- `autosaveDebounceMs`: 40-75ms (default 50ms)
- `autosaveMaxFlushMs`: 200-300ms (default 250ms)
- Immediate flush on:
  - window close
  - app quit
  - explicit save command
  - before agent execution
  - after agent apply
- Persistent restore checkpoints:
  - snapshot on open (original draft)
  - snapshot before agent apply
  - rolling recent snapshots (bounded by count/time)

## Limitations & Gaps

- Source material rarely provides exact debounce values for native editor autosave internals.
- Final ms tuning should be validated against PromptPad’s own editor startup/e2e benchmark suites on target hardware.

## Sources

| Source | URL | Quality | Accessed |
|---|---|---|---|
| Apple Document-Based App Programming Guide (autosave behavior/performance/cancellable autosaves) | https://developer.apple.com/library/archive/documentation/DataManagement/Conceptual/DocBasedAppProgrammingGuideForOSX/StandardBehaviors/StandardBehaviors.html | High (official platform docs) | 2026-02-17 |
| Apple Mac App Programming Guide (automatic data-saving checkpoints) | https://developer.apple.com/library/archive/documentation/General/Conceptual/MOSXAppProgrammingGuide/CoreAppDesign/CoreAppDesign.html | High (official platform docs) | 2026-02-17 |
| JetBrains IntelliJ save/revert docs (autosave triggers, actions on save, local history) | https://www.jetbrains.com/help/idea/saving-and-reverting-changes.html | High (official product docs) | 2026-02-17 |
| JetBrains system settings (autosave options, safe write, sync external changes) | https://www.jetbrains.com/help/idea/system-settings.html | High (official product docs) | 2026-02-17 |
| VS Code Jan 2024 update (auto-save per language/folder, disable autosave on errors for external tools) | https://code.visualstudio.com/updates/v1_86 | High (official product release notes) | 2026-02-17 |
| VS Code Nov 2016 update (Hot Exit backups/restore) | https://code.visualstudio.com/updates/v1_8 | High (official product release notes) | 2026-02-17 |
| Lodash debounce docs (`maxWait`, trailing, flush/cancel semantics) | https://lodash.com/docs/4.17.23#debounce | High (library reference) | 2026-02-17 |
| web.dev Optimize input delay (debounce to limit callback pressure, avoid interaction delay) | https://web.dev/articles/optimize-input-delay | High (Google engineering guidance) | 2026-02-17 |
| MDN debounce glossary (debounce mechanics) | https://developer.mozilla.org/en-US/docs/Glossary/Debounce | High (developer reference) | 2026-02-17 |
