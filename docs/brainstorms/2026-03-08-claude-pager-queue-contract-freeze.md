---
date: 2026-03-08
topic: claude-pager-queue-contract-freeze
status: active
---

# Claude Pager Queue Contract Freeze for TurboDraft

## Purpose
Freeze the queue compatibility assumptions before TurboDraft begins any shared queue file write/sync implementation.

## Source-of-truth findings
Claude Pager currently persists session-scoped queue files under:

- `~/.claude/queues/<key>.queue`

Observed behavior from the Claude Pager code path:

- queue file is newline-delimited
- current write shape is JSON per line with:
  - `id`
  - `prompt`
  - `added_us`
- current reader is permissive:
  - if a line is JSON and has a string `prompt`, use that
  - otherwise treat the whole line as raw prompt text
- full rewrites are atomic via temp-file + rename
- empty queue deletes the queue file
- key derivation priority is:
  1. `CLAUDE_SESSION_ID`
  2. transcript basename
  3. `default`

## Frozen TurboDraft assumptions

### Read compatibility
TurboDraft queue reader must accept:
1. JSON object lines with at least a string `prompt`
2. legacy/plain raw prompt lines

### Identity compatibility
- If `id` is present, preserve it exactly.
- Do not re-key or regenerate IDs on a normal round trip.
- If older/legacy lines have no `id`, TurboDraft may synthesize an in-memory identity for UI purposes, but must not write back a destructive schema migration until the writer is implemented with explicit compatibility tests.

### Unknown-field compatibility
- Future TurboDraft writer must preserve unknown JSON keys when rewriting JSON lines.
- TurboDraft must not strip Pager-owned metadata on round trip.

### Text preservation
- Prompt text must round-trip losslessly, including multiline content and attachment-like tokens.
- TurboDraft must not interpret or normalize attachment tokens on write.

### Authoritative queue attachment identity
- TurboDraft must not derive queue identity heuristically when explicit metadata is present.
- `queuePath` from `session.open` is authoritative.
- `queueKey` is descriptive metadata, not a substitute for the exact path.

## Handshake compatibility matrix

### Old client → new TurboDraft server
- `SessionOpenParams` without queue fields remains valid.
- No queue attachment is created.

### Metadata client → new TurboDraft server
- Optional fields:
  - `source`
  - `queuePath`
  - `queueKey`
  - `queueFormatVersion`
- If `queuePath` is present and non-empty, TurboDraft creates a queue attachment context.

### Metadata absent
- TurboDraft remains fully agent-agnostic.
- No queue UI should be forced open.

### Metadata present
- TurboDraft may expose optional queue UI/state for that session only.
- Shared-file write/sync behavior is still blocked until the round-trip-safe writer milestone lands.

## Non-goals for this tranche
- No shared queue writes yet
- No queue watcher yet
- No queue reorder
- No queue schema migration

## Exit criteria before Q7
Do not start shared queue writer/watcher work until:
1. queue reader/writer tests prove unknown-field preservation
2. ID stability is covered by tests
3. plain-line compatibility is covered by tests
4. atomic rewrite behavior is covered by tests
