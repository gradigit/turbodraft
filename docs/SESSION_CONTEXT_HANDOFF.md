# TurboDraft Session Context Handoff

TurboDraft can accept optional invoking-session context so the `drafting_agent` is not forced to rewrite prompts blind.

This is receiver-side support only. Sender-side adoption in Claude Pager / Codex wrappers can happen later without more TurboDraft runtime changes.

## Transport

The `turbodraft.session.open` request accepts these optional fields:

- `source`
- `contextPath`
- `contextFormatVersion`

`TurboDraftOpen` also supports environment-variable passthrough for editor-hook flows:

- `TURBODRAFT_SESSION_SOURCE`
- `TURBODRAFT_SESSION_CONTEXT_PATH`
- `TURBODRAFT_SESSION_CONTEXT_FORMAT_VERSION`

## Supported context payloads

- plain UTF-8 text files
- JSON files (stored and forwarded as pretty-printed JSON text)

Current supported format version: `1`

## Current runtime behavior

- if a supported context attachment is present, TurboDraft loads it asynchronously
- `Improve Prompt` and `Chat Refine` append a clearly bounded background section:
  - `## Invoking Session Context (background only)`
- the prompt explicitly tells the `drafting_agent` to use that material only as background context and not copy it verbatim into the final refined prompt unless directly relevant
- if no context is attached, behavior is unchanged

## Intentional non-goals in this tranche

- no sender-side implementation in external repos
- no PromptPack/import work
- no special context UI beyond the existing drafting context inspector showing what was sent
