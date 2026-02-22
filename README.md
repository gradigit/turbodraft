# TurboDraft

A native macOS editor for AI CLI tool hooks. When Claude Code or Codex CLI asks for `$EDITOR`, TurboDraft opens in 10ms and gives you a Markdown editor that actually makes sense for writing prompts.

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

## Set as your editor

```sh
export VISUAL=turbodraft
```

That's it. Claude Code's `Ctrl+G` and Codex CLI's editor hooks will now open TurboDraft.

### Agentic install (repo copy + ask an agent to set up)

If an AI agent is setting up the repo, tell it to:
1. run `scripts/install --mode install --yes`
2. run `scripts/turbodraft-launch-agent install`
3. ensure `VISUAL=turbodraft` and `~/.local/bin` are configured in your shell

Detailed runbook: `docs/AGENT_INSTALL.md`
Wizard flow diagrams: `docs/INSTALL_WIZARD_FLOW.md`

`turbodraft` accepts positional file paths, `+N` line jump syntax, and `--line N`/`--column N` flags. It blocks until you close the editor tab, then returns focus to your terminal.

## LaunchAgent (recommended)

Keep `turbodraft-app` resident so opens are instant (~10ms) instead of cold-starting (~170ms):

```sh
scripts/turbodraft-launch-agent install
```

Check status or remove:
```sh
scripts/turbodraft-launch-agent status
scripts/turbodraft-launch-agent uninstall
```

## Performance

Measured on M1 Max, macOS 14. The LaunchAgent warm path is what matters day-to-day.

| Metric | P50 | P95 |
|--------|-----|-----|
| Warm open (LaunchAgent resident) | ~10ms | <50ms |
| Cold start (process launch) | ~170ms | ~200ms |
| Typing latency (keystroke to display) | <0.1ms | <0.1ms |
| Markdown highlight pass | <2ms | <5ms |
| Save round-trip | <1ms | <1ms |

Cold start is mostly `fork+exec+dyld+AppKit` bootstrap. The LaunchAgent skips all of that.

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
- `⌘Enter` Submit and close window (return control to calling CLI)
- `⌘F` Find
- `⌥⌘F` Replace
- `⌘G` / `⇧⌘G` Find next / previous
- `⌘E` Use selection for find

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
| `theme` | `"system"` | `"system"`, `"light"`, or `"dark"` |
| `editorMode` | `"reliable"` | `"reliable"` or `"ultra_fast"` |
| `agent.enabled` | `false` | Enable prompt-engineering agent |
| `agent.command` | `"codex"` | Path to Codex CLI |
| `agent.model` | `"gpt-5.3-codex-spark"` | Model for prompt engineering |
| `agent.backend` | `"exec"` | `"exec"`, `"app_server"`, or `"claude"` |

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
python3 scripts/bench_editor_e2e_ux.py --cold 5 --warm 20
```

Open/close benchmark suite (API primary, optional UI probe):
```sh
python3 scripts/bench_open_close_suite.py --cycles 20 --warmup 1 --retries 2
python3 scripts/bench_open_close_suite.py --cycles 20 --warmup 1 --retries 2 --user-visible --ui-cycles 20
python3 scripts/bench_open_close_real_cli.py --cycles 20 --warmup 1 --poll-ms 2
turbodraft --path /tmp/prompt.md --debug-ready-latency
```
`bench_open_close_real_cli.py` enforces a default readiness gate: fail when p95 > 80ms.
Methodology + schema: `docs/OPEN_CLOSE_BENCHMARK.md`

Baseline thresholds are in `bench/editor/baseline.json`. P95 values have headroom for CI variance.

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

### Ask-first contract (required)

Before running install/config/uninstall actions, ask the user short confirmation questions using your question tool (for example `AskUserQuestion`, `Question`, or your environment’s equivalent). Ask for:

1. mode: `install`, `update`, `configure`, `repair`, or `uninstall`
2. LaunchAgent behavior: `install`, `restart`, `skip`, or `uninstall`
3. shell config updates:
   - add `PATH` entry
   - set `VISUAL=turbodraft`

Never assume `--yes` unless user explicitly asks for non-interactive automation.

### Agent command mapping

- guided flow:
  ```sh
  scripts/install
  ```
- explicit non-interactive install/update:
  ```sh
  scripts/install --mode install --yes
  ```
- explicit non-interactive repair:
  ```sh
  scripts/install --mode repair --yes
  ```
- explicit configure choices:
  ```sh
  scripts/install --mode configure --yes --launch-agent <install|restart|skip|uninstall> --set-path <yes|no> --set-visual <yes|no>
  ```

### Required verification + report

After running commands, verify:
1. `turbodraft --help`
2. `scripts/turbodraft-launch-agent status`
3. shell config matches user choices

Then report:
- commands run
- files changed
- final status
- rollback/uninstall command
<!-- AGENT-INSTALL-END -->

</details>

## License

MIT
