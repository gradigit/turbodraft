# Prompt Eval Judge Hardening Report (2026-03-04)

## Goal
Harden LLM judge prompt + pairwise pipeline to production quality.

## What changed

### Pipeline fixes
- Added robust Gemini JSON extraction for noisy CLI output in:
  - `bench/prompt_eval/run_codex_prompt_eval.py`
  - `bench/prompt_eval/providers/promptfoo_cli_provider.py`
- Added Gemini usage extraction from `stats.models.*.tokens` (prompt/candidates/total/cached).
- Added baseline validation (`--baseline-variant`, default `overlay_baseline`) with fail-fast if missing.
- Changed default mirror policy to `critical` (from `always`) to reduce unnecessary reverse-pass cost on non-critical cases.
- Fixed family winner selection logic:
  - `best_variant` now requires meaningful superiority (`non_tie_n > 0` and `wins > losses`), otherwise `null`.
- Adjusted escalation near-tie logic:
  - added `--escalation-score-margin-points` (default `1.0`),
  - keeps relative margin check via `--escalation-score-margin-max`,
  - `--escalation-on-critical` now only escalates when another uncertainty signal exists.
- `evaluate_gates.py` now defaults to strict mode (`--non-strict` required to relax).
- Promptfoo provider defaults are now runner-specific (codex/claude/gemini).
- Dataset integrity tool now ignores helper balanced calibration files (`*_balanced*`).

### Default judge prompt decision
- `run_codex_prompt_eval.py` default judge prompt changed to:
  - `bench/prompt_eval/prompts/judge_pairwise_v2.md`

## Validation results

### Tests
- `python3 -m unittest discover -s bench/prompt_eval/tests -p 'test_*.py'`
- Result: **37 passed**.

### Integrity checks
- `check_dataset_integrity.py`: **ok**
- `validate_gate_manifest.py`: **ok**

### Key post-fix eval artifacts
- `pilot-mini-v2-postfix-20260304`
  - `model_call_count`: 9
  - `model_error_rate`: 0.0
  - `model_timeout_rate`: 0.0
  - `judge_secondary` usage populated (no longer empty)
  - `best_variant` correctly `null` when both variants lose baseline
- `pilot-mini-v1-postfix-20260304`
  - Also no provider errors/timeouts
- `pilot-dev-v2-esc-c2-postfix-20260304`
  - `model_call_count`: 16
  - `model_error_rate`: 0.0
  - `model_timeout_rate`: 0.0
  - strict-gate eval still fails (insufficient coverage/sample floors + orientation stability threshold)

## Adversarial/perf review highlights integrated
- Near-tie threshold scale mismatch fixed.
- Unsafe winner-labeling fixed.
- Strict gating default hardened.
- Runner-default mismatch fixed.
- Baseline missing-KeyError risk fixed.

## Production-readiness decision (current)
- **Infra robustness**: PASS
- **Judge prompt quality baseline**: PASS (current best default v2)
- **Strict promotion gate**: FAIL (expected at this sample size)

### Remaining to reach full production promotion
1. Run full real-provider phase cycle with sufficient family coverage and sample floors.
2. Generate/attach real-provider judge audit artifact(s) (transitivity/shadow/gold-anchor).
3. Re-run strict gate and require all checks green.
