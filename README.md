# TurboDraft

A native macOS editor for AI CLI tool hooks. When Claude Code or Codex CLI asks for `$EDITOR`, TurboDraft opens in ~10ms (resident) and is ready-to-type in ~50ms on the real Ctrl+G path.

## Why not vim/nano/VS Code?

Terminal editors work. But they weren't designed for writing prompts. VS Code takes seconds to open. vim doesn't highlight Markdown the way you'd want while drafting prompts.

TurboDraft sits in between: a resident macOS app that opens instantly via Unix socket and renders Markdown as you type.

## Install

One-line installer (interactive wizard):

```sh
curl -fsSL https://raw.githubusercontent.com/gradigit/turbodraft/main/scripts/install | bash
```

Prefer an agent to install for you? Paste this repo into Claude/Codex and ask it to follow the **AGENT INSTALL SECTION (FOR AI AGENTS)** in this README.

```text
Please install and configure TurboDraft for me from:
https://github.com/gradigit/turbodraft

Use the AGENT INSTALL SECTION in README.md.
Use your AskUserQuestion/Question tool to run this like an interactive install wizard.
Ask me confirmation questions before changing launch agent or shell config.
Then report commands run, files changed, and how to rollback.
```

Or clone and run locally:

```sh
git clone https://github.com/gradigit/turbodraft.git
cd turbodraft
scripts/install
```

The installer is a single entrypoint for:
- fresh install
- update
- configure (PATH / VISUAL / LaunchAgent)
- repair
- uninstall

Non-interactive mode for automation/agents:

```sh
scripts/install --mode install --yes
```

This builds release binaries, symlinks `turbodraft`, `turbodraft-app`, and `turbodraft-bench` into `~/.local/bin`, and restarts (or installs) the LaunchAgent when requested.

Make sure `~/.local/bin` is on your `PATH`.

## Features

- Performance-first editing:
  - ~10ms resident open latency
  - ~50ms ready-to-type latency on real Ctrl+G runs
  - ~150ms cold-start class when the app is not resident
- Markdown list editing:
  - Enter at start/middle/end of list items (nested + non-nested)
  - Shift+Enter soft line break inside list item
  - Smart Backspace list-marker removal/outdent
  - Tab / Shift+Tab indent-outdent
  - Ordered-list auto-renumbering after structural edits
  - Better task-list continuation and checkbox handling
- Prompt-improve workflow:
  - Canonical roles: `drafting_agent` (rewrite only) and `execution_agent` (executes tasks)
  - Undo/redo across repeated improve runs
  - Restore behavior aligned with active working buffer expectations
  - Adaptive drafting presets: coding, refactor, review, research, brainstorm
  - Pivot presets for Korean-first prompting:
    - `pivot_kr_en_translate` (faithful KR→EN translation)
    - `pivot_kr_en_reason_ko` (EN reasoning contract + final KO output)
    - `pivot_kr_en_optimize_ko` (KR→EN optimization + KO output contract)
  - Annotation channel support via strict markers (`<!-- @td(type): ... -->`) and quick inline prefixes (`@@ question: ...`)
  - Chat-refine sidebar with interactive assistant turns, iterative annotation, and optional immediate improve
- Native find + replace:
  - Inline find UI, replace next/all, match case, whole word, regex
  - Selection-to-find (`⌘E`), next/previous match navigation
- Paste and media handling:
  - Clipboard image/file paste support
  - `Ctrl+V` parity for terminal workflows that rely on Ctrl-based paste shortcuts
- Install and configure:
  - One-line bootstrap to interactive install/config/repair/uninstall wizard
  - Agent-install runbook where the agent itself acts as the install wizard
- Benchmarks and guardrails:
  - Open/close API suite for CI/nightly regression tracking
  - Real Ctrl+G benchmark mode against live Codex/Claude terminal workflows
  - RAM regression suite with CI/nightly memory gates (delta/residual/slope)

## Set as your editor

```sh
export VISUAL=turbodraft
```

That's it. Claude Code's `Ctrl+G` and Codex CLI's editor hooks will now open TurboDraft.

### Claude Code companion tool: claude-pager

If you use Claude Code and want to keep session context visible during editor handoff (instead of the usual blank terminal view while `Ctrl+G` is active), use the sister tool **claude-pager**:

- https://github.com/gradigit/claude-pager

`turbodraft` accepts positional file paths, `+N` line jump syntax, and `--line N`/`--column N` flags. It blocks until you close the editor tab, then returns focus to your terminal.

## LaunchAgent (recommended)

Keep `turbodraft-app` resident so opens are instant (~10ms) instead of cold-starting (~150ms):

```sh
scripts/turbodraft-launch-agent install
```

Check status or remove:
```sh
scripts/turbodraft-launch-agent status
scripts/turbodraft-launch-agent uninstall
```

## Performance

Latest benchmark freeze: **MacBook Air 13-inch (M4), 24GB RAM, macOS 26.2**.

### Real Ctrl+G path (steady-state n=50)

| Metric | Median (ms) | P95 (ms) |
|--------|-------------:|---------:|
| Trigger dispatch overhead | 2.5 | 2.6 |
| Keypress → window visible | 53.4 | 70.5 |
| Keypress → ready-to-type | 57.3 | 71.5 |
| Post-dispatch → ready-to-type | 54.7 | 68.9 |
| Close command → window disappear | 109.0 | 113.3 |

### API suite (42-cycle profile, steady-state n=40)

| Metric | Median (ms) | P95 (ms) |
|--------|-------------:|---------:|
| API open total | 66.8 | 82.5 |
| API close trigger → CLI exit | 6.7 | 28.0 |
| API cycle wall | 110.7 | 130.8 |

Cold-start path is currently in the **~150ms class** when TurboDraft is not resident.

> Why API numbers are higher than "~10ms":
> - `bench_open_close_suite.py` measures the full CLI/API lifecycle (connect + RPC + close/exit path), not just editor draw time.
> - It intentionally includes open/close orchestration overhead and is meant for CI regression tracking.
> - The "~10ms" figure refers to ultra-fast resident internals; practical ready-to-type latency is in the ~50ms class.

### RAM suite (20-cycle profile, steady-state n=18)

| Metric | Median (MiB) | P95 (MiB) |
|--------|-------------:|----------:|
| Peak delta (peak-idle) | 10.5 | 23.4 |
| Post-close residual | 9.8 | 23.5 |
| Memory slope (MiB/cycle) | 0.09 | - |

Current RAM regression gates (CI/nightly):
- Peak delta p95 ≤ 32 MiB
- Post-close residual p95 ≤ 30 MiB
- Memory slope ≤ 0.8 MiB/cycle

All RAM headline metrics exclude warmup cycles.

## Markdown support

TurboDraft highlights the Markdown you actually use when writing prompts:

- Headers (`#` through `######`)
- Unordered and ordered lists
- Task checkboxes (`- [ ]`, `- [x]`)
- Blockquotes (`>`)
- Inline code and fenced code blocks
- Bold, italic, strikethrough
- Inline links and bare URL detection
- Enter-key continuation for lists, tasks, and quotes
- Smart list behavior: split item in middle, new item at end, new item above at item start
- Shift+Enter line breaks within list items
- Auto-exit on empty list items
- Smart Backspace list marker removal / outdent
- Tab/Shift+Tab list indent/outdent
- Ordered-list renumbering after structural edits
- Task checkbox toggle by typing space on `[ ]` / `[x]`
- Paste URL over selected text to create a Markdown link

Tables, footnotes, and full CommonMark/GFM edge cases are out of scope. This is a prompt editor, not a documentation renderer.

## Keyboard highlights

- `⌘R` Improve Prompt
- `⌥⌘R` Chat with Drafting Agent (add refinement note / add+improve)
- `⌘Enter` Submit and close window (return control to calling CLI)
- `⇧⌘A` Insert drafting annotation marker (`<!-- @td(note): ... -->`)
- `⌘F` Find
- `⌥⌘F` Replace
- `⌘G` / `⇧⌘G` Find next / previous
- `⌘E` Use selection for find
- `Esc` Close find/replace UI
- `Ctrl+V` Clipboard paste parity (including image/file clipboard content)

## How it works

```
turbodraft <file>
  → Unix domain socket (~/Library/Application Support/TurboDraft/turbodraft.sock)
    → Resident AppKit app (turbodraft-app)
      → Editor window with Markdown highlighting
        → Close tab → CLI unblocks → terminal regains focus
```

JSON-RPC over content-length framed streams. `turbodraft` (a 36KB C binary) connects, sends `turbodraft.session.open`, and blocks on `turbodraft.session.wait` until you close the tab.

## Configuration

Initialize a config file:
```sh
turbodraft config init
```

Config lives at `~/Library/Application Support/TurboDraft/config.json`.

| Key | Default | Description |
|-----|---------|-------------|
| `autosaveDebounceMs` | `50` | Autosave debounce in milliseconds |
| `externalSessionQueues.enabled` | `true` | Enables attached external session queues (for example Claude Pager queue sessions) |
| `externalSessionQueues.autoRevealOnAttach` | `false` | Automatically opens the Queue panel when a supported external session queue attaches |
| `theme` | `"system"` | `"system"`, `"light"`, or `"dark"` |
| `editorMode` | `"reliable"` | `"reliable"` or `"ultra_fast"` |
| `agent.enabled` | `false` | Enable drafting agent |
| `agent.command` | `"codex"` | Path to Codex CLI |
| `agent.model` | `"gpt-5.3-codex-spark"` | Model for drafting |
| `agent.backend` | `"app_server"` | `"exec"`, `"app_server"`, or `"claude"` |
| `agent.draftingPreset` | `"legacy"` | `"legacy"`, `"research"`, `"coding"`, `"refactor"`, `"review"`, `"brainstorm"`, `"pivot_kr_en_translate"`, `"pivot_kr_en_reason_ko"`, `"pivot_kr_en_optimize_ko"` |
| `agent.pluginPolicy` | `"curated_allowlist"` | `"curated_allowlist"`, `"deny_all"`, `"allow_all"` |
| `agent.pluginAllowlist` | `[]` | Allowed plugins/tools when policy is curated allowlist |
| `agent.providerBackend` | `"direct"` | `"direct"` or `"litellm"` (`litellm` = direct primary + LiteLLM fallback) |
| `agent.taskInstructionMode` | `"abstract"` | How drafting instructs execution-agent task workflow |
| `agent.askQuestionScope` | `"refinement_only"` | Restrict drafting clarifications to refinement-only questions |
| `agent.annotationEnabled` | `true` | Enables drafting annotations |
| `agent.annotationFormat` | `"td_comment_v1"` | Drafting annotation syntax version |
| `agent.chatPanelEnabled` | `true` | Enables drafting chat panel mode (when available) |
| `agent.experimentalTerminalChatEnabled` | `false` | Experimental terminal-backed drafting chat integration |

For LiteLLM fallback mode (`agent.providerBackend = "litellm"`), TurboDraft keeps direct Codex as primary and forwards these env vars for fallback Codex runs:
- `OPENAI_BASE_URL` from `TURBODRAFT_LITELLM_BASE_URL` or `LITELLM_BASE_URL` (fallback: `http://127.0.0.1:4000`)
- `OPENAI_API_KEY` from `TURBODRAFT_LITELLM_API_KEY` or `LITELLM_API_KEY` (if present)

Override socket or config path:
```sh
TURBODRAFT_SOCKET=/path/to/sock turbodraft --path file.md --wait
TURBODRAFT_CONFIG=/path/to/config.json turbodraft --path file.md --wait
```

## Building from source

```sh
swift build            # debug build
swift build -c release # release build
swift test             # run all tests
scripts/run_editor_validation.sh   # phased editor/search validation
scripts/run_product_qa.sh          # product QA: validation + open/close smoke
scripts/install        # build + symlink + restart LaunchAgent
```

Requires Swift 5.10+ and macOS 13+.

## Benchmarks

Run the benchmark suite:

```sh
swift build -c release
.build/release/turbodraft-bench bench run --path /tmp/prompt.md --warm 50 --cold 5 --out /tmp/bench.json
.build/release/turbodraft-bench bench check --baseline bench/editor/baseline.json --results /tmp/bench.json
```

End-to-end UX benchmark (requires Accessibility permission):
```sh
python3 scripts/test_editor_find_replace_e2e.py --keep-fixture
python3 scripts/test_editor_undo_redo_e2e.py
```

Product QA suite:
```sh
scripts/run_product_qa.sh
RUN_REAL_UI=1 scripts/run_product_qa.sh
```
This layers required editor validation with API open/close regression smoke and an optional real Ctrl+G/Ctrl+Q local probe.
Methodology: `docs/PRODUCT_QA_SUITE.md`

Open/close benchmark suite:
```sh
python3 scripts/bench_open_close_suite.py --cycles 20 --warmup 1 --retries 2
python3 scripts/bench_open_close_real_cli.py --cycles 20 --warmup 1 --poll-ms 2
turbodraft --path /tmp/prompt.md --debug-ready-latency
```
`bench_open_close_real_cli.py` enforces a default readiness gate: fail when p95 > 80ms.
Methodology + schema: `docs/OPEN_CLOSE_BENCHMARK.md`

RAM benchmark suite:
```sh
python3 scripts/bench_ram_suite.py --cycles 20 --warmup 1 --retries 1 --enforce-gates
scripts/bench_ram_nightly.sh
```
Methodology + schema: `docs/RAM_BENCHMARK.md`

Baseline thresholds are in `bench/editor/baseline.json`. P95 values have headroom for CI variance.

## Prompt preset evaluation

The authoritative prompt-eval / judge-lock program now lives in the standalone repo:

- `../prompt-eval-turbodraft`

TurboDraft keeps local prompt-eval assets only as a temporary compatibility copy until the
PromptPack/import boundary is finished. Active benchmark, adjudication, judge-lock, and
prompt-optimization work should happen in the external repo, not here.

See:
- `docs/PROMPT_EVAL_REPO_SPLIT_2026-03-12.md`

TurboDraft-owned scope going forward:
- runtime prompt loading and routing,
- preset selection/integration,
- future PromptPack/import support.

## Architecture

| Module | Purpose |
|--------|---------|
| `TurboDraftApp` | AppKit GUI, window management, socket server |
| `TurboDraftCLI` | Benchmark CLI (`turbodraft-bench`) |
| `TurboDraftOpen` | Main CLI — C binary used as `$VISUAL` (`turbodraft`) |
| `TurboDraftCore` | Editor sessions, file I/O, directory watcher |
| `TurboDraftProtocol` | JSON-RPC message types |
| `TurboDraftTransport` | Unix domain socket server/client |
| `TurboDraftMarkdown` | Markdown syntax highlighting |
| `TurboDraftAgent` | Prompt-engineering integration (Codex + Claude) |
| `TurboDraftConfig` | User configuration |

<details>
<summary><strong>AGENT INSTALL SECTION (FOR AI AGENTS)</strong></summary>

<!-- AGENT-INSTALL-START -->
If you are an AI agent reading this repository, follow this section exactly.

### Act as an interactive install/config wizard (required)

Before running install/config/uninstall actions, you must ask the user short confirmation questions using your question tool (`AskUserQuestion`, `Question`, or equivalent). Do not skip this.

Collect these choices first:

1. mode: `install`, `update`, `configure`, `repair`, or `uninstall`
2. LaunchAgent behavior: `install`, `restart`, `skip`, or `uninstall`
3. shell config updates:
   - add `PATH` entry
   - set `VISUAL=turbodraft`

Never assume `--yes` unless the user explicitly requests non-interactive automation.

### Agent command mapping

- guided wizard (default):
  ```sh
  scripts/install
  ```
- non-interactive install/update:
  ```sh
  scripts/install --mode install --yes
  ```
- non-interactive repair:
  ```sh
  scripts/install --mode repair --yes
  ```
- configure with explicit choices:
  ```sh
  scripts/install --mode configure --yes --launch-agent <install|restart|skip|uninstall> --set-path <yes|no> --set-visual <yes|no>
  ```

### Required verification

After running install/config/repair, verify:
1. `turbodraft --help` works
2. `scripts/turbodraft-launch-agent status` matches requested state
3. shell config matches requested `PATH` / `VISUAL` choices

### Required report back to user

Report all of the following:
- commands run
- files changed
- final status
- rollback/uninstall command

Reference docs for agents:
- `docs/AGENT_INSTALL.md`
- `docs/INSTALL_WIZARD_FLOW.md`
<!-- AGENT-INSTALL-END -->

</details>

## License

MIT
