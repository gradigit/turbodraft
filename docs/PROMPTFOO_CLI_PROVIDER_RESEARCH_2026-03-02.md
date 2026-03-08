# Promptfoo CLI-Backed Provider Research
Date: 2026-03-02
Depth: full

## Scope
Determine whether Promptfoo can be retained as the eval harness while replacing API-key-dependent providers with local agent CLI execution (`codex exec`, `claude -p`).

## Key Questions
1. Can Promptfoo call custom executors instead of built-in API providers?
2. What provider interfaces are supported for robust integration?
3. What migration risks matter for production CI/CD?

## Findings

### 1) Promptfoo supports external/custom providers
- Promptfoo supports script-based custom providers and Python providers.
- This enables routing execution through local CLIs while still using Promptfoo's test matrix, assertions, and reporting.
- Confidence: High

### 2) Script provider vs Python provider tradeoff
- Script providers are fast to wire but less ergonomic for rich telemetry shaping.
- Python providers are better for structured wrapping (stderr handling, timeout handling, usage normalization, consistent error contracts).
- Confidence: High

### 3) Built-in OpenAI Codex SDK provider is not equivalent to local `codex exec`
- Promptfoo's OpenAI Codex SDK provider expects API-style credentials/configuration.
- For keyless local CLI operation, custom wrapper providers are the correct architecture.
- Confidence: High

### 4) Production requirement: normalize usage/cost semantics
- Promptfoo report stats can contain token usage and cost, but provider wrappers must map usage consistently.
- Without normalization, budget gates can under/over count.
- Confidence: High

## Decision
Adopt Promptfoo as orchestration harness and move split configs to a Python custom provider that executes:
- drafting path: `codex exec`
- optional shadow path: `claude -p`

## Sources
1. Promptfoo Custom Script Provider docs
   - https://www.promptfoo.dev/docs/providers/custom-script/
2. Promptfoo Python Provider docs
   - https://www.promptfoo.dev/docs/providers/python/
3. Promptfoo OpenAI Codex SDK provider docs
   - https://www.promptfoo.dev/docs/providers/openai-codex-sdk/
4. Promptfoo Claude Agent SDK provider docs
   - https://www.promptfoo.dev/docs/providers/claude-agent-sdk/
