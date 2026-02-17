#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

WARM=30
COLD=5
PROMPT_FILE=""
OUT_DIR=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --warm) WARM="$2"; shift 2 ;;
    --cold) COLD="$2"; shift 2 ;;
    --path) PROMPT_FILE="$2"; shift 2 ;;
    --out-dir) OUT_DIR="$2"; shift 2 ;;
    *)
      echo "Unknown argument: $1" >&2
      echo "Usage: scripts/bench_text_engine_spike.sh [--path <prompt.md>] [--warm N] [--cold N] [--out-dir <dir>]" >&2
      exit 2
      ;;
  esac
done

STAMP="$(date +%Y%m%d-%H%M%S)"
if [[ -z "$OUT_DIR" ]]; then
  OUT_DIR="$ROOT_DIR/tmp/bench_text_engine_spike_$STAMP"
fi
mkdir -p "$OUT_DIR"

if [[ -z "$PROMPT_FILE" ]]; then
  PROMPT_FILE="$OUT_DIR/prompt.md"
  cat >"$PROMPT_FILE" <<'EOF'
Draft prompt:
Implement autosave + conflict handling for a markdown editor and keep startup under 50ms.
EOF
fi

if [[ ! -f "$PROMPT_FILE" ]]; then
  echo "Prompt file not found: $PROMPT_FILE" >&2
  exit 2
fi

write_config() {
  local path="$1"
  local socket="$2"
  cat >"$path" <<EOF
{
  "socketPath": "$socket",
  "autosaveDebounceMs": 40,
  "theme": "system",
  "agent": {
    "enabled": false,
    "backend": "exec",
    "command": "codex",
    "model": "gpt-5.3-codex-spark",
    "timeoutMs": 60000,
    "webSearch": "cached",
    "promptProfile": "large_opt",
    "reasoningEffort": "low",
    "reasoningSummary": "auto",
    "args": []
  }
}
EOF
}

build_and_bench() {
  local variant="$1"
  local swiftc_flag="$2"
  local variant_dir="$OUT_DIR/$variant"
  local bin_dir="$variant_dir/bin"
  local config_path="$variant_dir/config.json"
  local socket_path="/tmp/promptpad-${STAMP}-${variant}.sock"

  mkdir -p "$bin_dir"
  rm -f "$socket_path"
  write_config "$config_path" "$socket_path"

  echo "==> Building variant: $variant"
  if [[ -n "$swiftc_flag" ]]; then
    PROMPTPAD_SPIKE_CODEEDIT=1 swift build -c release --product promptpad --product promptpad-open --product promptpad-app -Xswiftc "$swiftc_flag"
  else
    swift build -c release --product promptpad --product promptpad-open --product promptpad-app
  fi

  cp .build/release/promptpad "$bin_dir/"
  cp .build/release/promptpad-open "$bin_dir/"
  cp .build/release/promptpad-app "$bin_dir/"

  echo "==> Benchmarking variant: $variant"
  PROMPTPAD_CONFIG="$config_path" "$bin_dir/promptpad" bench run \
    --path "$PROMPT_FILE" \
    --warm "$WARM" \
    --cold "$COLD" \
    --out "$variant_dir/results.json"
}

build_and_bench "nstextview" ""
build_and_bench "codeedit_textview" "-DPROMPTPAD_USE_CODEEDIT_TEXTVIEW"

python3 - "$OUT_DIR" <<'PY'
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
base = json.loads((root / "nstextview" / "results.json").read_text())
exp = json.loads((root / "codeedit_textview" / "results.json").read_text())

def fmt(v):
    return f"{v:.2f}"

keys = sorted(set(base["metrics"]) | set(exp["metrics"]))
print("\n=== Text Engine Spike Summary (lower is better) ===")
print(f"{'metric':40s} {'NSTextView':>12s} {'CodeEdit':>12s} {'delta(ms)':>12s} {'delta(%)':>10s}")
for k in keys:
    b = base["metrics"].get(k)
    e = exp["metrics"].get(k)
    if b is None or e is None:
        continue
    d = e - b
    p = (d / b * 100.0) if b else 0.0
    print(f"{k:40s} {fmt(b):>12s} {fmt(e):>12s} {fmt(d):>12s} {p:>9.1f}%")

print(f"\nArtifacts: {root}")
PY
