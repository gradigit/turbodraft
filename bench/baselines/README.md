# Pairwise baselines

This folder is for **human-reviewed baseline** prompt-engineering outputs used by the benchmark harness.

## Why
Pairwise evaluation is more stable when every candidate is compared against a fixed, high-quality baseline that you’ve reviewed, instead of “best available in this run” (which can change as models/configs change).

## Naming convention
For each draft fixture `bench/fixtures/<name>.md`, put a baseline at:

`bench/baselines/<name>.md`

Example:
- Draft: `bench/fixtures/dictation_flush_mode.md`
- Baseline: `bench/baselines/dictation_flush_mode.md`

## Generate a baseline (example)
Generate with your “best possible” generator (example uses `gpt-5.3-codex` + `xhigh`):

```sh
python3 scripts/bench_codex_prompt_engineer.py \
  --draft bench/fixtures/dictation_flush_mode.md \
  --models gpt-5.3-codex \
  --efforts xhigh \
  -n 1 --backend exec \
  --save-outputs tmp/baseline_out
```

Then copy the produced output file to `bench/baselines/dictation_flush_mode.md` and review it.

## Run pairwise comparisons against the baseline dir
```sh
python3 scripts/bench_codex_prompt_engineer.py \
  --draft bench/fixtures/dictation_flush_mode.md \
  --models gpt-5.3-codex-spark \
  --efforts low,medium,high,xhigh \
  -n 1 --backend exec \
  --pairwise --pairwise-model gpt-5.3-codex --pairwise-effort xhigh \
  --pairwise-baseline-dir bench/baselines \
  --save-outputs tmp/pairwise_outputs
```

