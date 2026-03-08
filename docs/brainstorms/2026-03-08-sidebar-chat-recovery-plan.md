---
date: 2026-03-08
topic: sidebar-chat-recovery-plan
status: active
---

# Sidebar Chat Recovery Plan

## What We're Building
Safely recover the previously built right-side drafting chat panel from the snapshot branch, then use that recovered panel as the foundation for future queue integration.

## Approaches considered

### Approach A — Cherry-pick the whole snapshot
**Pros:** fastest apparent recovery.
**Cons:** unsafe; huge diff; risks reintroducing stale behavior and conflicting with later prompt-eval/config changes.
**Verdict:** reject.

### Approach B — Targeted port by slices (recommended)
**Pros:** preserves prior work while keeping the current branch stable; lets us review each layer.
**Cons:** slower than a blanket cherry-pick.
**Verdict:** best option.

### Approach C — Rebuild from scratch
**Pros:** clean architecture.
**Cons:** wastes already-built, working UI; highest risk of losing product detail.
**Verdict:** reject.

## Recommended slice order
1. **Panel shell recovery**
   - right-side panel container
   - resize handle
   - visibility state + open/close entrypoints
   - no chat actions yet
2. **Chat surface recovery**
   - transcript
   - composer
   - attachment strip
   - utility/action rows
3. **Chat behavior recovery**
   - send/stream/apply-suggestion/add-note/add-improve behavior
   - adapter wiring
4. **Regression hardening**
   - no window resize coupling
   - hide/show semantics
   - theme/font/state persistence
5. **Queue groundwork (later milestone)**
   - add `Queue` as a sibling panel/tab on the recovered right-side host

## Acceptance criteria for recovery milestone
- `Chat Refine` is available again when chat panel is enabled.
- Opening chat shows the full right-side drafting panel.
- Panel resizing never resizes the whole app window.
- `Close` hides the panel without breaking the main editor.
- Existing `Improve Prompt` flow still works.
- No loss of current prompt-engineering backend behavior/config.

## Key decisions
- Recover the sidebar before queue integration.
- Treat the recovered panel as a **generic right panel host**, not a Claude-specific surface.
- Keep future queue integration optional and metadata-driven.

## Open questions
- Which snapshot behaviors are still desirable exactly as-is versus needing cleanup during port?
- Should `Chat Refine` remain a separate button from `Improve Prompt`, or should it become a generic “Open Panel” affordance later?

## Next steps
- Draft a file-by-file port checklist from `5dc675b`.
- Run a plan critique before any code port.
- Implement slice 1 only, then test.
