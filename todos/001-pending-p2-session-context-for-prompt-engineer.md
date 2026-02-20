# Session Context for Prompt Engineer Agent

**Status:** pending
**Priority:** p2
**Tags:** feature, prompt-engineer, ux

## Problem Statement

When a user opens TurboDraft via Ctrl+G from Claude Code CLI (or Codex CLI), the "Improve Prompt" agent has zero context about the ongoing CLI session — no conversation history, no file context, no error messages being debugged.

This means the prompt engineer is working blind. It can only see:
- The text in the editor
- The instruction (from config)
- Attached images

It cannot tailor prompt improvements based on what the user is actively working on in their CLI session.

## Desired Behavior

The improve prompt agent should receive relevant session context from the invoking CLI, such as:
- Recent conversation turns (or a summary)
- Files being discussed / edited
- Current task or goal
- Error messages being debugged

## Possible Approaches

1. **Environment variable**: CLI sets an env var (e.g., `TURBODRAFT_SESSION_CONTEXT`) with a file path pointing to a JSON/text dump of recent context. TurboDraft reads it on launch.
2. **Sidecar file**: CLI writes a `.<basename>.context.json` alongside the temp file it passes to `$VISUAL`. TurboDraft detects and reads it.
3. **RPC extension**: If TurboDraft is already running (LaunchAgent), the CLI could send context via the existing Unix domain socket before opening the editor.
4. **Stdin/protocol**: Extend the editor protocol beyond plain text file — e.g., a structured format that includes both the prompt text and session context.

## Acceptance Criteria

- [ ] Prompt engineer agent receives at least recent conversation context from the invoking CLI
- [ ] Context is used to improve prompt suggestions (not just ignored)
- [ ] Works with both Claude Code CLI and Codex CLI
- [ ] Graceful fallback when no context is available (current behavior)
