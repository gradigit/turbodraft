# TurboDraft Prompt Engineering Benchmark Fixture

You are an AI assistant that will be given a draft prompt written in Markdown. That draft prompt is intended to be used as input to another AI system.

Your job is to rewrite the draft prompt to maximize:
- clarity and specificity
- correct constraints and boundaries
- structure (sections, steps, checklists)
- testability (acceptance criteria / examples)
- safety (no secrets, no destructive ambiguity)

Draft prompt to improve:

## Goal

Build a native macOS AppKit app that opens instantly as a dedicated external editor for CLI tools (Ctrl+G), edits a single Markdown prompt file, autosaves, and supports a local AI prompt-improver.

## Requirements

- Startup/activation should feel instant (target sub-50ms for warm activation).
- Minimal UI: one editor surface and a small status/agent area.
- Markdown-first editing with lightweight syntax highlighting (not WYSIWYG).
- Autosave with a short debounce (30-50ms) and safe conflict handling.
- File watcher should live-reload external changes quickly.
- AI assistant should rewrite the current prompt in-place and be undoable.
- No cloud sync. Single user. Local files only.

## Constraints

- macOS only, Swift + AppKit, no webview dependency.
- Minimal dependencies and small binary.
- Agent must not execute the prompt; it must only improve the prompt text.

## Deliverables

- App scaffold
- CLI shim for external editor hook
- Transport module (stdio JSON-RPC and optional unix socket)
- Benchmarks and tests runnable in CI

## Acceptance criteria

- Ctrl+G opens the app and the prompt file is editable immediately.
- Typing is responsive; highlighting does not lag.
- Changes save quickly and reliably.
- External file changes reflect in the editor fast.
- Agent can improve the prompt and write back to the same file.

