# Prompt Eval Repo Split — 2026-03-12

## Status

The authoritative prompt-eval control plane has been split out of TurboDraft into a standalone repo:

- `../prompt-eval-turbodraft`

## Why

This separates:

- TurboDraft product/runtime development
- prompt-eval research, adjudication, judge lock, and prompt optimization

The split avoids churn in the product repo and lets the eval system evolve independently.

## Ownership boundary

### `prompt-eval-turbodraft` owns

- judge-lock workflow
- human adjudication workflow
- benchmark datasets
- prompt-eval orchestration / gating
- prompt candidate generation and optimization
- prompt-eval docs/research/review artifacts

### TurboDraft still owns

- app/runtime behavior
- `drafting_agent` routing and adapters
- prompt loading/integration behavior
- output guards
- preset selection UX
- future PromptPack/import integration

## Transitional duplication

The following content still exists in TurboDraft temporarily because runtime code still reads it directly:

- `bench/presets`
- `bench/preambles`

That duplication is intentional until the PromptPack/import boundary is implemented.

## Active guidance

- Do active prompt-eval work in `prompt-eval-turbodraft`.
- Do not treat `bench/prompt_eval` in TurboDraft as the long-term home of the eval system.
- Keep TurboDraft changes focused on runtime/integration concerns.

## Follow-up work

1. Keep the new eval repo standalone and healthy.
2. Later design/export a PromptPack artifact from the eval repo.
3. Cut TurboDraft over to PromptPack/import-based prompt ownership.
