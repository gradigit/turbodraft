# TurboDraft Session Attachment Handoff

TurboDraft can accept optional session attachment metadata during `session.open`:

- invoking-session context, so the `drafting_agent` is not forced to rewrite prompts blind
- external queue metadata, so the optional queue surface can attach to the current session without Claude-specific hard-coding

This is receiver-side support only. Sender-side adoption in Claude Pager / Codex wrappers can happen later without more TurboDraft runtime changes.

## Transport

The `turbodraft.session.open` request accepts these optional fields:

- `source`
- `queuePath`
- `queueKey`
- `queueFormatVersion`
- `contextPath`
- `contextFormatVersion`

Both `turbodraft` and `turbodraft-bench open` support environment-variable passthrough for editor-hook flows:

- `TURBODRAFT_SESSION_SOURCE`
- `TURBODRAFT_SESSION_QUEUE_PATH`
- `TURBODRAFT_SESSION_QUEUE_KEY`
- `TURBODRAFT_SESSION_QUEUE_FORMAT_VERSION`
- `TURBODRAFT_SESSION_CONTEXT_PATH`
- `TURBODRAFT_SESSION_CONTEXT_FORMAT_VERSION`

## Supported queue metadata

- queue files must be addressed by absolute path
- current supported queue format version: `1`
- unsupported queue format versions remain attached but are surfaced as unsupported in the queue UI

## Supported context payloads

- plain UTF-8 text files
- JSON files (stored and forwarded as pretty-printed JSON text)

Current supported format version: `1`

## Current runtime behavior

- if a supported queue attachment is present, TurboDraft can surface the external queue panel for that session (subject to user settings)
- if a supported context attachment is present, TurboDraft loads it asynchronously
- `Improve Prompt` and `Chat Refine` append a clearly bounded background section:
  - `## Invoking Session Context (background only)`
- the prompt explicitly tells the `drafting_agent` to use that material only as background context and not copy it verbatim into the final refined prompt unless directly relevant
- if no context is attached, behavior is unchanged

## Intentional non-goals in this tranche

- no sender-side implementation in external repos
- no PromptPack/import work
- no special context UI beyond the existing drafting context inspector showing what was sent
