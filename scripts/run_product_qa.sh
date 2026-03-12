#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

timestamp="$(date +%Y%m%d-%H%M%S)"
out_root="${PRODUCT_QA_OUT_DIR:-tmp/product-qa/$timestamp}"
api_out="$out_root/open-close-api"
real_out="$out_root/open-close-real-cli"

open_close_cycles="${OPEN_CLOSE_CYCLES:-6}"
open_close_warmup="${OPEN_CLOSE_WARMUP:-1}"
open_close_retries="${OPEN_CLOSE_RETRIES:-2}"

real_ui_cycles="${REAL_UI_CYCLES:-4}"
real_ui_warmup="${REAL_UI_WARMUP:-1}"
real_ui_poll_ms="${REAL_UI_POLL_MS:-2}"
real_ui_trigger_mode="${REAL_UI_TRIGGER_MODE:-auto}"
real_ui_gate_metric="${REAL_UI_GATE_METRIC:-uiOpenReadyPostDispatchMs}"
real_ui_max_ready_p95_ms="${REAL_UI_MAX_READY_P95_MS:-80}"

mkdir -p "$out_root"

printf '\n[product-qa] phase 1/3: editor validation\n'
scripts/run_editor_validation.sh

printf '\n[product-qa] phase 2/3: API open/close regression smoke\n'
python3 scripts/bench_open_close_suite.py \
  --cycles "$open_close_cycles" \
  --warmup "$open_close_warmup" \
  --retries "$open_close_retries" \
  --out-dir "$api_out"

if [[ "${RUN_REAL_UI:-0}" == "1" ]]; then
  printf '\n[product-qa] phase 3/3: real Ctrl+G/Ctrl+Q probe\n'
  python3 scripts/bench_open_close_real_cli.py \
    --cycles "$real_ui_cycles" \
    --warmup "$real_ui_warmup" \
    --poll-ms "$real_ui_poll_ms" \
    --trigger-mode "$real_ui_trigger_mode" \
    --gate-metric "$real_ui_gate_metric" \
    --max-ready-p95-ms "$real_ui_max_ready_p95_ms" \
    --out-dir "$real_out"
else
  printf '\n[product-qa] phase 3/3: real Ctrl+G/Ctrl+Q probe skipped (set RUN_REAL_UI=1 to enable)\n'
fi

printf '\nproduct QA suite complete\n'
printf 'artifacts: %s\n' "$out_root"
