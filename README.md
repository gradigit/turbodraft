# TurboDraft

A native macOS editor for AI CLI tool hooks. When Claude Code or Codex CLI asks for `$EDITOR`, TurboDraft opens in 10ms and gives you a Markdown editor that actually makes sense for writing prompts.

## Why not vim/nano/VS Code?

Terminal editors work. But they weren't designed for writing prompts. VS Code takes seconds to open. vim doesn't highlight Markdown the way you'd want while drafting prompts.

TurboDraft sits in between: a resident macOS app that opens instantly via Unix socket and renders Markdown as you type.

## Install

```sh
git clone https://github.com/gradigit/turbodraft.git
cd turbodraft
scripts/install
```

This builds release binaries, symlinks `turbodraft`, `turbodraft-app`, `turbodraft-open`, and `turbodraft-editor` into `~/.local/bin`, and restarts the LaunchAgent if installed.

Make sure `~/.local/bin` is on your `PATH`.

## Set as your editor

```sh
export EDITOR="turbodraft-editor"
```

That's it. Claude Code's `Ctrl+G` and Codex CLI's editor hooks will now open TurboDraft.

`turbodraft-editor` accepts `--line N`, `--column N`, and `+N` line jump syntax. It blocks until you close the editor tab, then returns focus to your terminal.

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
- Auto-exit on empty list items

Tables, footnotes, and full CommonMark/GFM edge cases are out of scope. This is a prompt editor, not a documentation renderer.

## How it works

```
CLI (turbodraft open)
  → Unix domain socket (~/Library/Application Support/TurboDraft/turbodraft.sock)
    → Resident AppKit app (turbodraft-app)
      → Editor window with Markdown highlighting
        → Close tab → CLI unblocks → terminal regains focus
```

JSON-RPC over content-length framed streams. The CLI connects, sends `turbodraft.session.open`, and blocks on `turbodraft.session.wait` until you close the tab.

`turbodraft-open` is a C binary that does the same thing without the Swift runtime. It's faster for the first-byte case but both paths converge on the same socket.

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
| `agent.backend` | `"exec"` | `"exec"` or `"app_server"` |

Override socket or config path:
```sh
TURBODRAFT_SOCKET=/path/to/sock turbodraft open --path file.md --wait
TURBODRAFT_CONFIG=/path/to/config.json turbodraft open --path file.md --wait
```

## Building from source

```sh
swift build            # debug build
swift build -c release # release build
swift test             # run all 58 tests
scripts/install        # build + symlink + restart LaunchAgent
```

Requires Swift 5.10+ and macOS 13+.

## Benchmarks

Run the benchmark suite:

```sh
swift build -c release
.build/release/turbodraft bench run --path /tmp/prompt.md --warm 50 --cold 5 --out /tmp/bench.json
.build/release/turbodraft bench check --baseline bench/editor/baseline.json --results /tmp/bench.json
```

End-to-end UX benchmark (requires Accessibility permission):
```sh
python3 scripts/bench_editor_e2e_ux.py --cold 5 --warm 20
```

Baseline thresholds are in `bench/editor/baseline.json`. P95 values have headroom for CI variance.

## Architecture

| Module | Purpose |
|--------|---------|
| `TurboDraftApp` | AppKit GUI, window management, socket server |
| `TurboDraftCLI` | CLI (`turbodraft open`, `turbodraft bench`) |
| `TurboDraftOpen` | Minimal C binary for fast-path opens |
| `TurboDraftCore` | Editor sessions, file I/O, directory watcher |
| `TurboDraftProtocol` | JSON-RPC message types |
| `TurboDraftTransport` | Unix domain socket server/client |
| `TurboDraftMarkdown` | Markdown syntax highlighting |
| `TurboDraftAgent` | Codex prompt-engineering integration |
| `TurboDraftConfig` | User configuration |

## License

MIT
