---
date: 2026-03-08
topic: turbodraft-shared-queue-sidebar-integration
status: active
---

# TurboDraft Shared Queue + Sidebar Integration

## What We're Building
Add optional shared-queue integration to TurboDraft for sessions launched from Claude Pager, without making TurboDraft Claude-specific or regressing its agent-agnostic use for Codex/manual sessions.

The key product shape should be:
- TurboDraft stays a general editor + drafting tool.
- Claude Pager can attach a session-scoped queue context when opening TurboDraft.
- TurboDraft can show and edit that queue in a right-side panel.
- The right-side panel should be generalized so it can also host the drafting chat UI that currently exists in backend/config form but is not wired into the current app UI.

## Why This Approach
The context packet is directionally correct: the queue file should remain the source of truth and TurboDraft should not invent a second queue system. But the packet under-specifies two important product issues:
1. TurboDraft is agent-agnostic, so the feature boundary must be an optional external-session attachment, not a Claude-specific app mode.
2. Queue editing needs a dedicated UI model; it should not hijack the main editor buffer.

A generalized right panel solves both problems. It keeps Claude-specific queue UI isolated behind explicit session metadata while also giving TurboDraft a place to restore the missing drafting chat UI.

## Current Code Reality
- `SessionOpenParams` currently supports only `path`, `line`, `column`, `requestId`, `cwd`, `protocolVersion`.
- `AppDelegate` handles `turbodraft.session.open`, but there is no queue metadata plumbing yet.
- `EditorViewController` currently renders the main editor and a bottom `Improve Prompt` button only.
- The old sidebar chat UI is not present in the current branch/UI.
- However, interactive chat infrastructure still exists in `TurboDraftAgent`, and `TurboDraftConfig.Agent.chatPanelEnabled` still exists, which means the app/backend split is currently inconsistent.

## Key Decisions
- **Use explicit launch metadata, not inference**: Claude Pager should pass `source`, `queuePath`, `queueKey`, and a queue format/version marker on `session.open`. TurboDraft should not guess from process names, cwd, or environment.
- **Hide queue integration behind attachment + setting**: queue UI appears only when valid queue metadata is attached and the user setting allows external queue integrations. Default behavior should remain invisible for normal sessions.
- **Reintroduce a generic right panel host**: do not build a queue-only sidebar. Build a generic right panel container with tabs/sections, initially `Queue` and later `Chat`.
- **Do not use the main editor for queue item editing**: the queue panel should own queue item editing. Main editor remains the opened file/session buffer.
- **Keep file-sync as v1 transport**: queue file remains the source of truth; use atomic writes + watcher reload + self-change suppression.
- **Require stable queue entry identity**: editing/deleting specific queue items safely needs per-entry IDs. If older queue lines lack IDs, synthesize on read and persist IDs on rewrite in a backward-compatible way.

## Recommended UX
### Panel model
Use a right-side panel inside the TurboDraft window:
- collapsed by default when no panel content is available
- resizable internally (must never resize the whole window)
- panel tabs:
  - `Queue` (only when external queue is attached)
  - `Chat` (only when chat panel feature is enabled and implemented)

### Queue tab
Layout:
- top: queue list
- bottom: selected item editor / detail view

Per row:
- short prompt preview
- maybe created time / source badge
- selected state

Supported v1 actions:
- select item
- edit selected item
- delete selected item
- create new item
- save changes back atomically

Explicitly defer for v1:
- reorder
- cross-app cursor sync
- live RPC queue coordination

### Visibility rules
- **Normal TurboDraft / Codex use**: no queue tab
- **Claude Pager launched with queue metadata**: queue tab becomes available
- if queue metadata exists and a user preference like `autoRevealAttachedQueue` is on, open the right panel with the `Queue` tab selected
- otherwise keep the panel collapsed but show an unobtrusive queue indicator/button

## Recommended Settings Shape
Do not create a broad “Claude mode”. Instead use generic integration settings, e.g.:
- `externalSessionQueues.enabled = false | true`
- `externalSessionQueues.autoRevealOnAttach = true | false`
- `agent.chatPanelEnabled = true | false` (already exists; should eventually become real again)

If we need a tri-state later, use:
- `off | automatic | always`

But `automatic` should still rely on explicit session metadata.

## Protocol Recommendation
Extend `turbodraft.session.open` with optional fields such as:
- `source`
- `queuePath`
- `queueKey`
- `queueFormatVersion`

Optional future field:
- `queueCapabilities`

This preserves agent-agnostic behavior while letting Claude Pager opt in cleanly.

## Risks / Anti-Patterns
- **Do not infer Claude launch context heuristically**.
- **Do not build a second queue store in TurboDraft**.
- **Do not edit queue items by replacing the main document content**.
- **Do not make the queue UI always visible**; it would confuse non-Claude sessions.
- **Do not revive the sidebar as a Claude-only surface**; it should be a generic right panel host.
- **Do not omit stable entry IDs** if TurboDraft will edit/delete specific queue records.
- **Do not let internal sidebar resizing mutate the app window size**; the panel must resize within the window only.

## Open Questions
- What exact queue line schema does Claude Pager currently persist, and can it safely preserve unknown fields like `id`?
- Should the first release support “new queue item from current document selection”, or only edit existing queue items + add blank item?
- Should the restored `Chat` tab be available in all sessions, or only when explicitly enabled in settings?

## Next Steps
1. Add session-open metadata support (`source`, `queuePath`, `queueKey`, `queueFormatVersion`).
2. Introduce a session-scoped `ExternalQueueContext` model.
3. Build queue file load/write/watch plumbing with atomic rewrite + debounced reload.
4. Reintroduce a generalized right panel host in the app window.
5. Implement the minimal `Queue` tab UI.
6. After panel shell exists, restore the dormant `Chat` panel into that same right-side host.
