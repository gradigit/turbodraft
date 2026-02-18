# Research: Prompt-engineering agent (Codex CLI integration)
Date: 2026-02-14
Depth: Full

## Executive summary
For TurboDraft, the “agent add-on” should behave like a dedicated prompt engineer:

- Input: the current Markdown prompt text.
- Output: a rewritten prompt optimized for clarity, constraints, structure, and testability.
- UX: one action (“Improve Prompt”), no extra user guidance required.

For implementation, OpenAI’s Codex CLI supports a non-interactive `exec` mode, reading from stdin and writing the final assistant message to a file. That is a good fit for a GUI editor that wants deterministic “replace buffer with improved draft” behavior without parsing styled console output.

## Key implementation findings

### Codex CLI supports non-interactive `exec`
Codex CLI provides:
- `codex exec` for scripting / non-interactive runs
- `--model` / `-m` to select a model
- `--output-last-message` / `-o` to write the final assistant message to a file
- `PROMPT` can be `-` to read the prompt from stdin
- Safety/automation flags like `--ask-for-approval` and sandbox controls

This enables a safe pattern:
1. Write an internal “prompt engineer” system/preamble + user task + current prompt text to stdin.
2. Run `codex exec ... -o <tmpfile> -`
3. Read `<tmpfile>` and replace the editor buffer.

### A strong pre-prompt avoids “executing the prompt”
To keep the agent from treating the content as an instruction to run, the prompt should:
- Define the role: “You are a prompt engineer rewriting a prompt for another model.”
- Provide a strict output contract: “Output only the improved prompt.”
- State prohibitions: “Do not execute the prompt; do not call tools; do not add commentary.”
- Preserve intent and formatting: “Keep Markdown; keep user’s meaning.”

OpenAI’s prompt guidance and migration examples commonly enforce “output only X” and “rewrite/improve prompt” patterns, which map directly to this task.

## Sources
| Source | URL | Quality | Accessed | Notes |
|---|---|---:|---:|---|
| Codex CLI: Command line options (includes `exec`, `-m`, `-o`) | https://developers.openai.com/codex/cli#command-line-options | High | 2026-02-14 | Non-interactive `exec` and `--output-last-message` behavior |
| OpenAI Prompt Migration Guide (revise system prompt example) | https://cookbook.openai.com/examples/prompt_migration_guide | High | 2026-02-14 | Shows “revise system prompt” workflows + strong output constraints |
| Introducing GPT-5.3-Codex-Spark (model family context) | https://openai.com/index/introducing-gpt-5-3-codex-spark/ | High | 2026-02-14 | Confirms model family name + positioning |

