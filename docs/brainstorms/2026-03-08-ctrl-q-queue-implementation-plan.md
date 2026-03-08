---
date: 2026-03-08
topic: turbodraft-ctrl-q-and-shared-queue-implementation-plan
status: active
---

# TurboDraft Ctrl+Q + Shared Queue Implementation Plan

## Goal
Implement the next safe integration tranche for Claude Pager parity:

1. Fix TurboDraft session-close semantics so `turbodraft.session.wait` resolves only after the targeted session UI is actually gone.
2. Add optional queue metadata handshake on `turbodraft.session.open`.
3. Prepare, but do not yet fully ship, shared queue file sync until the queue line contract is frozen and round-trip safe.

## Research inputs
- Claude Pager `Ctrl+Q` already uses the correct RPC shape:
  - `session.open`
  - long-lived `session.wait`
  - `session.close` on `Ctrl+Q`
- TurboDraft currently resolves `session.wait` too early because `session.markClosed()` runs before `orderOut/onClosed`.
- Claude Pager queue file is already the source of truth:
  - `~/.claude/queues/<key>.queue`
  - JSONL records with `id`, `prompt`, `added_us`
  - permissive reader that tolerates plain legacy prompt lines
  - atomic rewrite via temp + rename
- Hook injection path uses the exact queue file and session id identity on the Claude Code side, so TurboDraft should accept explicit queue metadata instead of re-deriving it.

## Reviewed implementation order

### Q6a — Ctrl+Q protocol correctness
Ship first.

#### Implementation
- Keep `session.close` / `session.wait` RPC surface unchanged.
- Change the window close pipeline so:
  1. autosave is still attempted with a timeout budget,
  2. UI teardown always runs,
  3. `session.markClosed()` happens only after the visible session is actually closed/ordered out.
- Add an explicit window-controller close entrypoint so protocol-driven close uses the same authoritative path as user close.

#### Acceptance criteria
- `turbodraft.session.close(sessionId)` targets exactly one session.
- `turbodraft.session.wait(sessionId)` returns `userClosed` only after that session window is no longer visible.
- Timeout in the autosave race must not leave the waiter hanging forever.
- Existing manual close behavior remains responsive.

#### Tests
- App-level regression proving `waitUntilClosed` completion observes a non-visible window.
- Close-path regression for duplicate/rapid close requests.

### Q6b — Queue contract freeze + compatibility matrix
Must happen before shared write/sync behavior.

#### Implementation
- Freeze the queue line assumptions we are willing to preserve:
  - JSONL object line with at least `prompt`
  - preserve `id` when present
  - preserve unknown keys on round-trip once queue writer lands
  - preserve raw/plain-line compatibility on read
- Freeze the handshake compatibility matrix:
  - old client → new server
  - metadata client → new server
  - metadata absent → no queue attachment
  - metadata present → queue attachment available

#### Acceptance criteria
- No metadata fields are required for normal TurboDraft clients.
- No queue sync/write work proceeds without a round-trip-safe queue contract.

### Q6c — Optional queue metadata handshake + attachment plumbing
Ship after Q6a.

#### Implementation
- Extend `SessionOpenParams` with optional:
  - `source`
  - `queuePath`
  - `queueKey`
  - `queueFormatVersion`
- Add a normalized `ExternalQueueAttachment` runtime model on the TurboDraft side.
- Parse/store attachment data in `AppDelegate`.
- Pass attachment data into the active window/controller/view so queue UI can be added later without rethreading the protocol.

#### Acceptance criteria
- Existing clients that send only old `SessionOpenParams` continue to work unchanged.
- Sessions launched with queue metadata retain that metadata for the lifetime of the session.
- Reused sessions can refresh/update their attached queue metadata.

#### Tests
- Protocol encode/decode tests for new optional fields.
- App-level test that attachment metadata is stored and exposed to the active editor session surface.

### Q7 — Shared queue file model + round-trip-safe reader/writer
Blocked on Q6b contract freeze.

### Q8 — Queue panel UI on the recovered right panel host
Blocked on Q7.

## Self-critique
- Do not start queue writes before schema preservation is nailed down.
- Do not rely on inferred Claude context.
- Do not couple queue editing to the main editor buffer.
- Do not introduce a new close RPC if the existing contract can be tightened safely.

## Adversarial review deltas incorporated
- Added explicit Ctrl+Q milestone instead of burying it inside queue work.
- Added queue contract freeze before any shared file write/sync implementation.
- Added compatibility matrix requirement for metadata handshake.
- Added missing close/wait end-to-end regression coverage.
