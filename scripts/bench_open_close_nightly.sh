#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

STATE_DIR="tmp/open-close-nightly"
PREV_REPORT="$STATE_DIR/previous-report.json"
LATEST_LINK="$STATE_DIR/latest"
mkdir -p "$STATE_DIR"

compare_arg=()
if [[ -f "$PREV_REPORT" ]]; then
  compare_arg=(--compare "$PREV_REPORT")
fi

python3 scripts/bench_open_close_suite.py \
  --cycles 20 \
  --warmup 1 \
  --retries 2 \
  --no-clean-slate \
  "${compare_arg[@]}"

latest_report="$(ls -t tmp/bench_open_close_*/report.json | head -1)"
latest_dir="$(dirname "$latest_report")"
cp "$latest_report" "$PREV_REPORT"
rm -f "$LATEST_LINK"
ln -sfn "$(cd "$latest_dir" && pwd)" "$LATEST_LINK"

echo "nightly_latest\t$LATEST_LINK"
echo "nightly_report\t$latest_report"
