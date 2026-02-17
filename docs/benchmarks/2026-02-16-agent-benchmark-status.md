# PromptPad agent benchmark status (2026-02-16)

This document snapshots the benchmark/research state before Codex quota reset so we can resume quickly.

## Current default decision

- Backend default: `exec`
- Web search default: `cached`
- Prompt profile default: `large_opt`
- Rationale: best observed quality/latency tradeoff in completed matrix runs.

## Completed matrix results (quality + latency)

Source:
- `tmp/bench_matrix_20260216-052959/matrix_summary_all6.json`
- `tmp/bench_matrix_20260216-052959/matrix_summary_all6.tsv`

Ranking (pairwise win rate primary):
1. `large_opt__web-cached` — pairwise `0.778` (28W/8L), median `5.441s`, p95 `6.963s`
2. `large_opt__web-disabled` — pairwise `0.694` (25W/11L), median `5.122s`, p95 `7.858s`
3. `core__web-cached` — pairwise `0.611` (22W/14L), median `4.982s`, p95 `6.975s`
4. `core__web-disabled` — pairwise `0.556` (20W/16L), median `4.676s`, p95 `6.376s`
5. `extended__web-disabled` — pairwise `0.444` (16W/20L), median `5.190s`, p95 `7.262s`
6. `extended__web-cached` — pairwise `0.441` (15W/19L), median `5.396s`, p95 `7.081s`

Latency tradeoff between chosen quality default and speed default:
- `large_opt + web-cached` vs `core + web-disabled`:
  - median: `+0.766s` (`+16.4%`)
  - p95: `+0.586s` (`+9.2%`)

## Controlled prompt-cache results

Exec backend:
- `tmp/prompt_cache_controlled_20260216-190611/results.json`
- Background cached floor: `12416`
- Extra-cache hit rate over floor:
  - exact repeat: `0.20`
  - tail mutation: `0.20`
  - prefix mutation: `0.00`

App-server backend:
- `tmp/prompt_cache_controlled_appserver_20260216-192424/results.json`
- App-server startup: `~0.074s`
- Background cached floor: `1920`
- Extra-cache hit rate over floor:
  - exact repeat: `0.50`
  - tail mutation: `0.60`
  - prefix mutation: `0.00`

Interpretation:
- Stable prefix is required for additional cache benefit.
- Tail mutations preserve cache potential.
- Prefix mutations remove additional cache benefit.

## In-progress / blocked runs

Matrix reruns including new cache columns (`tmp/bench_matrix_20260216_cachemetrics_v*`) were blocked by Codex quota.

Observed CLI block:
- `ERROR: You've hit your usage limit for codex_bengalfox. Try again at Feb 22nd, 2026 6:22 AM.`

## Resume commands after quota reset

Full matrix:

```sh
python3 scripts/bench_prompt_engineer_matrix.py \
  --drafts-file bench/fixtures/profiles/profile_set.txt \
  --preamble-variants "core=bench/preambles/core.md,large_opt=bench/preambles/large-optimized-v1.md,extended=bench/preambles/extended.md" \
  --web-search-modes "disabled,cached" \
  --models gpt-5.3-codex-spark \
  --efforts low \
  --backend both \
  -n 7 \
  --pairwise \
  --pairwise-model gpt-5.3-codex \
  --pairwise-effort xhigh \
  --pairwise-n 3 \
  --pairwise-baseline-dir bench/baselines/profiles \
  --out-dir tmp/bench_matrix_postreset
```

If a run partially completes, rerun only missing cells by narrowing `--preamble-variants` and `--web-search-modes` while reusing the same `--out-dir`.

## Related research docs

- `docs/research/research-giant-preamble-size-2026-02-15.md`
- `docs/research/research-prompt-eval-checklist-and-engineered-format-2026-02-15.md`
- `docs/research/research-prompt-evaluation-2026-02-14.md`

## TODO: benchmark expansion

- [ ] Add a dedicated prompt-quality benchmark track with blinded pairwise judging and calibration against periodic human labels.
- [ ] Add a production-representative dataset pack (short dictation, medium spec, long noisy, ambiguous) and report per-profile quality + latency.
