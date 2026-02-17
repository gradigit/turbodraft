# PromptPad prompt-quality benchmarks

This track measures only prompt-engineering model output quality and model latency.
It does not include editor open/save/render metrics.

## Primary metrics

- `exec_quality_pass_rate`
- `exec_pairwise_win_rate`
- `app_quality_pass_rate`
- `app_pairwise_win_rate`
- backend-specific latency medians/p95

## Baseline

- `bench/prompt/baseline.json`

## Runner

```sh
python3 scripts/bench_prompt_suite.py \
  --drafts-file bench/fixtures/profiles/profile_set.txt \
  --models gpt-5.3-codex-spark \
  --efforts low \
  --backend both
```

## Manual check

```sh
python3 scripts/check_prompt_benchmark.py --summary tmp/bench_prompt_*/matrix_summary.json --baseline bench/prompt/baseline.json
```
