#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

timestamp="$(date +%Y%m%d-%H%M%S)"
out_root="${PRODUCT_QA_OUT_DIR:-tmp/product-qa/$timestamp}"

open_close_cycles="${OPEN_CLOSE_CYCLES:-6}"
open_close_warmup="${OPEN_CLOSE_WARMUP:-1}"
open_close_retries="${OPEN_CLOSE_RETRIES:-2}"
attached_open_close_cycles="${ATTACHED_OPEN_CLOSE_CYCLES:-3}"
attached_open_close_warmup="${ATTACHED_OPEN_CLOSE_WARMUP:-1}"

real_ui_cycles="${REAL_UI_CYCLES:-4}"
real_ui_warmup="${REAL_UI_WARMUP:-1}"
real_ui_poll_ms="${REAL_UI_POLL_MS:-2}"
real_ui_trigger_mode="${REAL_UI_TRIGGER_MODE:-auto}"
real_ui_gate_metric="${REAL_UI_GATE_METRIC:-uiOpenReadyPostDispatchMs}"
real_ui_max_ready_p95_ms="${REAL_UI_MAX_READY_P95_MS:-80}"

mkdir -p "$out_root"
out_root="$(cd "$out_root" && pwd)"
api_out="$out_root/open-close-api"
attached_out="$out_root/open-close-attached"
real_out="$out_root/open-close-real-cli"

queue_fixture="$out_root/product-qa.queue"
context_fixture="$out_root/session-context.json"
cat > "$queue_fixture" <<'EOF'
{"id":"product-qa-item","prompt":"Refine this prompt without changing intent.","added_us":1730000000000000}
EOF
cat > "$context_fixture" <<'EOF'
{
  "invoker": "product-qa",
  "purpose": "Attached session metadata smoke",
  "notes": [
    "Keep drafting behavior agent-agnostic.",
    "Treat this as background context only."
  ]
}
EOF

printf '\n[product-qa] phase 1/4: editor validation\n'
scripts/run_editor_validation.sh

printf '\n[product-qa] phase 2/4: API open/close regression smoke\n'
python3 scripts/bench_open_close_suite.py \
  --cycles "$open_close_cycles" \
  --warmup "$open_close_warmup" \
  --retries "$open_close_retries" \
  --out-dir "$api_out"

printf '\n[product-qa] phase 3/4: attached queue/context API smoke\n'
python3 scripts/bench_open_close_suite.py \
  --cycles "$attached_open_close_cycles" \
  --warmup "$attached_open_close_warmup" \
  --retries "$open_close_retries" \
  --session-source "product-qa" \
  --queue-path "$queue_fixture" \
  --queue-key "product-qa" \
  --queue-format-version 1 \
  --context-path "$context_fixture" \
  --context-format-version 1 \
  --out-dir "$attached_out"

if [[ "${RUN_REAL_UI:-0}" == "1" ]]; then
  printf '\n[product-qa] phase 4/4: real Ctrl+G/Ctrl+Q probe\n'
  python3 scripts/bench_open_close_real_cli.py \
    --cycles "$real_ui_cycles" \
    --warmup "$real_ui_warmup" \
    --poll-ms "$real_ui_poll_ms" \
    --trigger-mode "$real_ui_trigger_mode" \
    --gate-metric "$real_ui_gate_metric" \
    --max-ready-p95-ms "$real_ui_max_ready_p95_ms" \
    --out-dir "$real_out"
else
  printf '\n[product-qa] phase 4/4: real Ctrl+G/Ctrl+Q probe skipped (set RUN_REAL_UI=1 to enable)\n'
fi

printf '\nproduct QA suite complete\n'
printf 'artifacts: %s\n' "$out_root"
