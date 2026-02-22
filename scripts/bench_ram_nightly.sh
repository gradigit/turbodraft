#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

stamp="$(date +%Y%m%d-%H%M%S)"
out_dir="tmp/bench_ram_nightly_${stamp}"
prev="tmp/bench_ram_nightly_latest/report.json"

args=(
  --cycles 52
  --warmup 2
  --retries 2
  --save-iterations 12
  --payload-bytes 48000
  --enforce-gates
  --max-peak-delta-p95-mib 36
  --max-post-close-residual-p95-mib 32
  --max-memory-slope-mib-per-cycle 0.8
  --out-dir "$out_dir"
)

if [[ -f "$prev" ]]; then
  args+=(--compare "$prev")
fi

echo "Running RAM nightly benchmark..."
PYTHONPATH=. python3 scripts/bench_ram_suite.py "${args[@]}"

mkdir -p tmp/bench_ram_nightly_latest
rm -f tmp/bench_ram_nightly_latest/report.json tmp/bench_ram_nightly_latest/cycles.jsonl
cp "$out_dir/report.json" tmp/bench_ram_nightly_latest/report.json
cp "$out_dir/cycles.jsonl" tmp/bench_ram_nightly_latest/cycles.jsonl

echo "RAM nightly benchmark complete: $out_dir"
