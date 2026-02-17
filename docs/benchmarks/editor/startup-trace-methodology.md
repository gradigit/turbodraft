# PromptPad editor startup trace methodology

This benchmark is the primary editor performance signal. It avoids typing/saving automation phases and isolates open readiness.

## Flow under test

1. Harness receives `Ctrl+G`.
2. Harness launches `promptpad open --path <fixture>` (no `--wait`).
3. PromptPad opens target file and reaches editable readiness.
4. `promptpad open` returns to harness.

## Metrics

- `ctrlGToPromptPadActiveMs`: Ctrl+G to PromptPad activation.
- `ctrlGToEditorCommandReturnMs`: Ctrl+G to `promptpad open` return (editor ready path).
- `phasePromptPadReadyMs`: `ctrlGToEditorCommandReturnMs - ctrlGToPromptPadActiveMs`.

## Why this removes most automation jitter

- Timing origin is inside harness at Ctrl+G capture.
- No automated typing/saving/window-close path is included.
- No token-write validation path is needed.

## Quality gates

- Valid run requires:
  - `benchmarkMode == startup`
  - `returnCode == 0`
  - required metrics present
- Required valid counts per mode (`--cold`, `--warm`)
- Minimum valid rate per mode (default `0.98`)

## Statistical method

- p95: nearest-rank percentile
- median CI: bootstrap 95% confidence interval (2000 rounds)
