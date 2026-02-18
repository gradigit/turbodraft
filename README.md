# PromptPad

Native macOS prompt editor optimized for external-editor hooks (Claude Code / Codex CLI).

## Install

```sh
scripts/install
```

Builds release binaries, symlinks `promptpad`, `promptpad-app`, `promptpad-open`, and `promptpad-editor` into `~/.local/bin`, and restarts the LaunchAgent if installed.

Run `scripts/install` after every code change to update the running app.

### Development build

```sh
swift build
```

### LaunchAgent (recommended)

Keeps `promptpad-app` resident for instant editor open (~10ms warm vs ~170ms cold):

```sh
scripts/promptpad-launch-agent install
```

Status / remove:
```sh
scripts/promptpad-launch-agent status
scripts/promptpad-launch-agent uninstall
```

## External editor hook

Most tools expect an `$EDITOR`-style command that receives a single file path argument and blocks until you finish editing.

Use the included shim:

```sh
export EDITOR="promptpad-editor"
```

`promptpad-editor` uses reliable mode by default (`promptpad open` + `--wait`).
For fastest-launch experiments, opt in to fast mode (`promptpad-open` first):

```sh
export PROMPTPAD_EDITOR_MODE=fast
```

Unset `PROMPTPAD_EDITOR_MODE` to return to reliable mode.

## Prompt Markdown profile (v1)

PromptPad is optimized for prompt authoring, not full Markdown-spec coverage.

Guaranteed/maintained behavior:
- Headers (`#` ... `######`)
- Lists (unordered + ordered)
- Task checkboxes (`- [ ]`, `- [x]`)
- Blockquotes (`>`)
- Inline code and fenced code blocks
- Emphasis (`*`, `**`, `~~`)
- Inline links (`[label](url)`)
- Bare URL detection
- Enter-key continuation for lists, tasks, ordered lists, and quotes
- Enter-key list exit on empty items

Out of scope in v1 (no guarantees):
- Tables
- Footnotes
- Full CommonMark/GFM conformance edge cases
- Advanced extensions beyond prompt-authoring needs

## Run (dev)

Terminal 1 (app):
```sh
swift run promptpad-app
```

Terminal 2 (CLI):
```sh
swift run promptpad --help
swift run promptpad open --path /tmp/prompt.md --wait
swift run promptpad bench run --path /tmp/prompt.md --warm 50 --cold 5 --out /tmp/promptpad-bench.json
swift run promptpad bench check --baseline bench/editor/baseline.json --results /tmp/promptpad-bench.json
```

## Benchmark (release)

```sh
swift build -c release
.build/release/promptpad bench run --path /tmp/prompt.md --warm 50 --cold 5 --out /tmp/promptpad-bench.json
.build/release/promptpad bench check --baseline bench/editor/baseline.json --results /tmp/promptpad-bench.json
```

`bench run` also emits:
- `warm_textkit_highlight_p95_ms` (text-engine microbenchmark: single-character insert + markdown highlight pass)

Text engine spike benchmark (A/B `NSTextView` vs `CodeEditTextView`):
```sh
scripts/bench_text_engine_spike.sh --warm 30 --cold 5 --path /tmp/prompt.md
```
This builds two release variants and writes side-by-side results under `tmp/bench_text_engine_spike_*`.
Normal builds do not resolve the CodeEdit dependency. The spike variant enables it only for the `CodeEditTextView` build path.

Speed target (warm/resident path):
- `warm_ctrl_g_to_editable_p95_ms < 50`

## Config

```sh
swift run promptpad config init
# or:
PROMPTPAD_CONFIG=/path/to/config.json swift run promptpad config init --path "$PROMPTPAD_CONFIG"
```

Config keys (JSON):
- `autosaveDebounceMs`: integer milliseconds (default `50`; reduce for more aggressive save, raise for more write coalescing).
- `theme`: `"system"` (default), `"light"`, `"dark"`
- `editorMode`: `"reliable"` (default) or `"ultra_fast"` (faster open path, less strict readiness guarantees)
- `agent.enabled`: `true|false` (default `false`). Can also be toggled from the app menu: `Agent -> Enable Prompt Engineer`.
- `agent.command`: Codex CLI executable (default `"codex"`, must be in `PATH`).
- `agent.model`: model id (default `"gpt-5.3-codex-spark"`).
- `agent.timeoutMs`: request timeout (default `60000`).
- `agent.backend`: `"exec"` (spawn per request; default) or `"app_server"` (warm resident `codex app-server`).
- `agent.webSearch`: `"cached"` (default), `"disabled"`, `"live"`.
- `agent.promptProfile`: `"large_opt"` (default), `"core"`, `"extended"`.
- `agent.reasoningEffort`: `"minimal"|"low"|"medium"|"high"|"xhigh"` (default `"low"`). Note: Spark models reject `"minimal"` and will be coerced to `"low"`.
- `agent.reasoningSummary`: `"auto"` (default), `"concise"`, `"detailed"`, `"none"`.
- `agent.args`: array of extra Codex CLI args (advanced). For `app_server`, only `-c/--config/--enable/--disable` are forwarded.

In-app controls:
- Prompt engineering is manual-only. It runs only when you click `Improve Prompt` (button) or use `Agent -> Improve Prompt` (`Cmd+Shift+R`).
- Theme can be switched from `View -> Theme` (`System`, `Light`, `Dark`).
- Editor runtime mode can be switched from `View -> Editor Mode` (`Reliable`, `Ultra Fast`).

Open-latency telemetry:
- PromptPad writes JSONL records to:
  - `/Users/<you>/Library/Application Support/PromptPad/telemetry/editor-open.jsonl`
- Records include stage timings such as `connectMs`, `rpcOpenMs`, `totalMs`, and app-side `openMs`.

## Test

```sh
swift test
```

## Editor benchmark suite (latency/perf only)

Editor-only runner (no model calls, no prompt-quality scoring):

```sh
python3 scripts/bench_editor_suite.py --path bench/fixtures/dictation_flush_mode.md --warm 50 --cold 8
```

Optional launch/lifecycle matrix in same run:

```sh
python3 scripts/bench_editor_suite.py --with-launch-matrix
```

Startup trace benchmark (strict editor-open metrics, no typing/saving automation phase):

```sh
python3 scripts/bench_editor_startup_trace.py --cold 10 --warm 40 --min-valid-rate 0.98
```

True end-to-end UX benchmark (Ctrl+G trigger + focus + type/save/close + refocus):

```sh
python3 scripts/bench_editor_e2e_ux.py --cold 5 --warm 20
```

Notes:
- Requires macOS Accessibility permission for your terminal app (`osascript` keystroke automation).
- Uses `promptpad-e2e-harness` for real Ctrl+G-triggered external-editor cycles.

## Prompt benchmark suite (quality/latency only)

Prompt-only runner (model-backed; no editor startup metrics):

```sh
python3 scripts/bench_prompt_suite.py \
  --drafts-file bench/fixtures/profiles/profile_set.txt \
  --models gpt-5.3-codex-spark \
  --efforts low \
  --backend both
```

Prompt threshold checker (uses `bench/prompt/baseline.json`):

```sh
python3 scripts/check_prompt_benchmark.py --summary tmp/bench_prompt_*/matrix_summary.json --baseline bench/prompt/baseline.json
```

## Codex prompt-engineering benchmark internals (agent backend)

Bench `codex exec` vs warm `codex app-server` using a real Markdown draft prompt and basic output checks:

```sh
python3 scripts/bench_codex_prompt_engineer.py -n 9
python3 scripts/bench_codex_prompt_engineer.py --backend app-server --models gpt-5.3-codex-spark --efforts low,medium,high,xhigh -n 9
python3 scripts/bench_codex_prompt_engineer.py --backend exec --models gpt-5.3-codex --efforts low,medium -n 9
```

Use a custom prompt-engineering system preamble:

```sh
python3 scripts/bench_codex_prompt_engineer.py \
  --drafts "$(paste -sd, bench/fixtures/profiles/profile_set.txt)" \
  --system-preamble-file bench/preambles/core.md \
  --models gpt-5.3-codex-spark --efforts low \
  --backend both -n 9 --pairwise --pairwise-model gpt-5.3-codex --pairwise-effort xhigh \
  --pairwise-baseline-dir bench/baselines/profiles \
  --json-out tmp/bench_custom_preamble/results.json
```

## Matrix benchmark harness (preamble x web-search)

Sweep benchmark cells across preamble variants and web-search modes:

```sh
python3 scripts/bench_prompt_engineer_matrix.py \
  --drafts-file bench/fixtures/profiles/profile_set.txt \
  --preamble-variants "core=bench/preambles/core.md,large_opt=bench/preambles/large-optimized-v1.md,extended=bench/preambles/extended.md" \
  --web-search-modes "disabled,cached" \
  --models gpt-5.3-codex-spark --efforts low \
  --backend both -n 7 \
  --pairwise --pairwise-model gpt-5.3-codex --pairwise-effort xhigh --pairwise-n 3 \
  --pairwise-baseline-dir bench/baselines/profiles
```

Outputs:
- Per-cell raw benchmark JSON and generated outputs: `tmp/bench_matrix_*/<variant>__web-<mode>/`
- Aggregate matrix summaries:
  - `tmp/bench_matrix_*/matrix_summary.json`
  - `tmp/bench_matrix_*/matrix_summary.tsv`

Historical benchmark/research snapshot:
- `docs/benchmarks/2026-02-16-agent-benchmark-status.md`
